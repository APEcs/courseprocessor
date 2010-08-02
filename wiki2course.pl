#!/usr/bin/perl -W

## @file
# Script to export the contents of a course namespace in the PEVE development wiki
# to html files in a standard PEVE course data structure.
#
# For full documentation please see http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Wiki2course.pl
#
# @copy 2008, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.7.0 (2 August 2010)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}

use lib ("$path/modules"); # Add the script path for module loading
use Digest;
use Encode qw(encode);
use File::Path;
use Getopt::Long;
use MediaWiki::API;
use MIME::Base64;
use Pod::Usage;
use XML::Simple;

# Constants used in various places in the code
# The current version
use constant VERSION  => "1.7 (2 August 2010) [Course Processor v3.7.0]";

# The maximum number of levels of page transclusion that may be processed
use constant MAXLEVEL => 5;

# Location of the API script in the default wiki.
use constant WIKIURL  => 'http://elearn.cs.man.ac.uk/devwiki/api.php';


# Settings for flash export, generally shouldn't need modifying
my $flashversion = "7,0,0,0"; # Flash version
my $flashaccess  = "false";   # Allow or disallow script access (false is a Good Idea)
my $flashconnect = "false";   # do not start up java connector
# Allowed arguments
my %flashargs    = ("play"  => 1, "loop"   => 1, "quality" => 1, "devicefont" => 1, "bgcolor" => 1, "scale" => 1,
                    "align" => 1, "salign" => 1, "base" => 1, "meni" => 1, "vmode" => 1, "SeamlessTabbing" => 1, 
                    "flashvars" => 1, "name" => 1, "id" => 1 );


# Where is Andre Simon's `highlight`?
my $highlight = "/usr/bin/highligh";

# various globals set via the arguments
my ($basedir, $username, $password, $namespace, $apiurl, $fileurl, $convert, $verbose, $mediadir) = ('', '', '', '', WIKIURL, '', '', 0, 'media');
my $man = 0;
my $help = 0;

# Approved html tags
my @approved_html = ("a", "pre", "code", "br", "object", "embed", 
                     "table", "tr", "td", "th", "tbody", "thead", 
                     "ul", "ol", "li", 
                     "dl", "dt", "dd",
                     "h1", "h2", "h3", "h4", "h5", "h6", "h7",
                     "hr",
                     "sub","sup",
                     "tt", "b", "i", "u", "div", "span", "strong", "blockquote",

                     # Mediawiki and Extension tags...
                     "math",      # needed to convert <math> to [latex]
                     "flash",     # required for <flash> tag processing
                     "streamflv", # required for <streamflv> tag processing
                     "popup",     # required for <popup> tag processing
                     "source",    # source formatting
                    );


# -----------------------------------------------------------------------------
#  Utility functions

## @fn $ path_join(@fragments)
# Take an array of path fragments and will concatenate them together with '/'s
# as required. It will ensure that the returned string *DOES NOT* end in /
#
# @param fragments The path fragments to join together.
# @return A string containing the path fragments joined with forward slashes.
sub path_join {
    my @fragments = @_;

    my $result = "";
    foreach my $fragment (@fragments) {
        $result .= $fragment;
        # append a slash if the result doesn't end with one
        $result .= "/" if($result !~ /\/$/);
    }

    # strip the trailing / if there is one
    return substr($result, 0, length($result) - 1) if($result =~ /\/$/);
    return $result;
}


## @fn $ makedir($name)
# Attempt to create the specified directory if needed. This will determine
# whether the directory exists, and if not whether it can be created.
#
# @param name The name of the directory to create.
# @return true if the directory was created, false otherwise.
sub makedir {
    my $name = shift;

    # If the directory exists, we're okayish...
    if(-d $name) {
        print "WARNING: Dir $name exists, the contents will be overwritten.\n";
        return 1;

    # It's not a directory, is it something... else?
    } elsif(-e $name) {
        # It exists, and it's not a directory, so we have a problem
        print "ERROR: dir $name corresponds to a file or other resource.\n";

    # Okay, it doesn't exist in any form, time to make it
    } else {
        eval { mkpath($name); };

        if($@) {
            print "ERROR: Unable to create directory $name: $@\n";
            return 0;
        }
        return 1;
    }

    return 0;
}


## @fn $ get_password()
# Obtain a password from the user. This will read the user's password 
# from STDIN after prompting for input, and disabling terminal echo. Once
# the password has been entered, echo is re-enabled. If no password is 
# entered, this will die and not return. 
#
# @return A string containing the user's password.
sub get_password {
    my ($word, $tries) = ("", 0);
    
    # We could do something fancy with Term::ReadChar or something, but this
    # code is pretty much tied to *nix anyway, so just use stty...
    system "stty -echo";

    # repeat until we get a word, or the user presses return three times.
    while(!$word && ($tries < 3)) {
        print STDERR "Password: ";  # print to stderr to avoid issues with output redirection.
        chomp($word = <STDIN>);
        print STDERR "\n";
        ++$tries;
    } 
    # Remember to reinstate the echo...
    system "stty echo";

    # Bomb if the user has just pressed return
    die "ERROR: No password provided\n" if(!$word);

    # Otherwise send back the string
    return $word;
}


## @fn $ make_highlight_cmd($lang, $style, $linenumber, $linestart, $tabwidth, $outfile, $cssfile)
# Generate the command line to use when invoking highlight (as part of source tag
# conversion). This generates a command that is intended to be invoked via a pipe,
# such that this script writes the code the be highlighted over the pipe, and the
# results are saved to files.
#
# @note As stated in the desceiption, this command assumes that it will be invoked such that
#       the content to be highlighted will be passed over a pipe to highlight, and then 
#       highlight will write the corresponding html and css to temporary files. This method
#       is the most straightforward option - the alternatives involve things like messing with
#       IPC::Open2/3 or IPC::Run, and using read and write pipes. While this is doable, it is
#       a royal pain in the arse to do without possible blocking issues and other IPC
#       nightmares. Writing over a pipe, and then parsing the result files is more wasteful 
#       in terms of filesystem access, but it is massively simpler and more reliable.
#
# @param lang       The language used in the source content.
# @param style      The highlight style
# @param linenumber True to enable line numbering, false otherwise. Defaults to false.
# @param linestart  The line number to start numbering from, defaults to 1.
# @param tabwidth   If set, tabs are replaced with this many spaces. Defaults to undef.
# @param outfile    The file to write highlighted content to.
# @param cssfile    The file to write css information to.
# @return The command to issue to highlight source.
sub make_highlight_cmd {
    my ($lang, $style, $linenumber, $linestart, $tabwidth, $outfile, $cssfile) = @_;
    my $result = $highlight;

    # We will always have fragment, lang, style, output, and css output
    $result .= " -f -O /tmp -o ".quotemeta($outfile).
                          " -S ".quotemeta($lang).
                          " -s ".quotemeta($style).
                          " -c ".quotemeta($cssfile);

    # Handle line numbering if needed
    $result .= " -l " if($linenumber);
    $result .= " -m $linestart" if($linestart && $linestart =~ /^\d+$/);

    # And tabs
    $result .= " -t $tabwidth" if($tabwidth && $tabwidth =~ /^\d+$/);

    return $result;
}


## @fn $ process_hilight_files($id, $outfile, $cssfile)
# Load the contents of the specified hilight output files, and generate a stylesheet definition
# and pre block from them.
#
# @param id         The page-unique id of the source block.
# @param outfile    The file containing processed source.
# @param cssfile    The file containing the stylesheet information.
# @return The highlighted, processed source.
sub process_hilight_files {
    my $id = shift;
    my $outfile = shift;
    my $cssfile = shift;

    # We don't need no steenking newlines
    my $oldnl = $/;
    undef $/;

    # Read in the highlighted source html
    open(OUTF, $outfile)
        or die "ERROR: Unable to read highlight output file: $!\n";

    my $source = <OUTF>;
    close(OUTF);

    # And now the stylesheet
    open(CSSF, $cssfile)
        or die "ERROR: Unable to read highlight css file: $!\n";

    my $css = <CSSF>;
    close(CSSF);

    # Best out newlines back now
    $/ = $oldnl;

    # First, trash everything in the css up to the pre, we don't need or want it,
    # and remove any trailing whitespace as that's not needed either
    $css =~ s/^.*?^\.hl/.hl/sm;
    $css =~ s/\s*$//;
    
    # Now shove the id into the class names, this allows for multiple styles on the same page
    $css =~ s/.hl/.hlid$id/g;

    # Same for the html
    $source =~ s/class="hl /class="hlid$id /g;

    # Compose the result, throwing out the stylesheet and then the pre block
    return "<style type=\"text/css\">/*<![CDATA[*/\n".$css."\n/*]]>*/</style>\n<pre>$source</pre>";
}    


## @fn $ highlight_fragment($id, $args, $source)
# Run Andre Simon's highlight over the specified source, with the provided args. This
# will generare a string containing an inline stylesheet and pre block with the specified
# source pocessed through highlight.
#
# @param id     Page-unique id of the source block to process.
# @param args   A reference to a hash containing options to control the highlighting. This
#               <b>must</b> minimally contain 'lang' and 'style' values.
# @param source The source to highlight.
# @return A string containing the highlighted source, and the stylesheet to support it.
sub highlight_fragment {
    my $id     = shift;
    my $args   = shift;
    my $source = shift;

    # Check that we have the required gubbins
    if(!$args -> {"lang"} || !$args -> {"style"}) {
        print "ERROR: Attempt to invoke highlight without sufficient information.\n";
        return "<p style=\"error\">Uhable to highlight source, missing lang or style.</p><pre>$source</pre>";
    }

    # Get a unique id for the source
    my $sha1 = Digest -> new("SHA-1");
    # The first two may not be system-wide unique if two w2cs are working in parallel, time is likely to be, pid *will* be
    $sha1 -> add($source, $id, time(), $$); 
    my $uid = $sha1 -> hexdigest();

    # Now we need temp files for the source output and stylesheet
    # This shouldn't be a security risk
    my $outfile = "w2c_hlout_$uid.frag";
    my $cssfile = "w2c_hlcss_$uid.css";

    # Make the command we need
    my $cmd = make_highlight_cmd($args -> {"lang"}, $args -> {"style"}, 
                                 $args -> {"line"}, $args -> {"start"},
                                 $args -> {"tabwidth"},
                                 $outfile, $cssfile);

    # run highlight, and throw the source at it
    open(HLIGHT, "|-", $cmd)
        or die "ERROR: Unable to launch highlight: $!\n";

    print HLIGHT $source;

    close(HLIGHT);

    # Okay, do we have output files? If we are missing either, print out an error...
    if(!-f path_join("/tmp", $outfile)) {
        unlink path_join("/tmp", $cssfile) if(-f path_join("/tmp", $cssfile));
        print "ERROR: highlight did not produce any output. Unable to process source.\n";
        return "<p style=\"error\">Uhable to highlight source, highlight did not produce any output.</p><pre>$source</pre>";
    }        
    if(!-f path_join("/tmp", $cssfile)) {
        unlink path_join("/tmp", $outfile) if(-f path_join("/tmp", $outfile));
        print "ERROR: highlight did not produce any stylesheet output. Unable to process source.\n";
        return "<p style=\"error\">Uhable to highlight source, highlight did not produce any stylesheet output.</p><pre>$source</pre>";
    }        

    return process_hilight_files($id, path_join("/tmp", $outfile), path_join("/tmp", $cssfile));
}


# -----------------------------------------------------------------------------
#  Step processing functions

## @fn $ process_list($text, $type, $startt, $endt)
# Convert a bullet or number list in wiki markup to html. This will recursively
# handle multilevel lists, provided that each list level starts with at least one
# level-one item, ie:
#
# *
# **
# **
#
# Is valid, whereas 
#
# **
# *
# 
# Is not. This also does not support #:, *:, :*, or :# 
#
# @param text   A string containing the list to process.
# @param type   The list tupe, should be '*' or '#'
# @param startt The start tag prepended to the processed items.
# @param endt   The end tag appended to the processed items.
# @return The processed list.
sub process_list {
    my $text   = shift;
    my $type   = shift;
    my $startt = shift;
    my $endt   = shift;

    # Trim the data
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    # convert single level
    $text =~ s{^\Q$type\E\s*((?:[^*#]).*?)$}{<li>$1</li>}gm;

    # Okay, we have processed all level 1 entries, now the hard part of dealing with level 2+
    # Trim off any remaining level 1 markers 
    $text =~ s/^\Q$type\E//gm;

    # Now recurse
    $text =~ s{^(\*\s*.*?)(?=\n\s*?\n|^\#|\z|<li)}{process_list($1, '*', '<li><ul>', '</ul></li>')}gmse;
    $text =~ s{^(\#\s*.*?)(?=\n\s*?\n|^\*|\z|<li)}{process_list($1, '#', '<li><ol>', '</ol></li>')}gmse;

    # Fix up nesting problems
    $text =~ s{</li>\s+<li><([uo]l)>}{\n<$1>}g;

    return "$startt\n".$text."\n$endt\n";
}


## @fn $ process_deflist($text)
# Process the contents of a definition list into html. This will do a fairly 
# smplistic conversion from wiki markup to html. Note that this does not support
# nested defintion lists, or ordered/unordered lists inside definition lists.
#
# @param text The text of the definition list.
# @return The processed html definition list.
sub process_deflist {
    my $text = shift;
    
    $text =~ s{^;\s*(.*?)(?:^:|^;|$)}{<dt>$1</dt>}gm;
    $text =~ s{^:\s*(.*?)(?:^:|^;|$)}{<dd>$1</dd>}gm;
    
    return "<dl>$text</dl>\n";
}


## @fn $ process_pre($count, $lead)
# Mark up the first level of pre tags with special markers. This will return 
# <pre:00> if the current pre is at the top level, or just &lt;pre&gt; if it
# is not.
#
# @param count A reference to the pre level counter.
# @param lead  A string containing either '/' or '', depending on whether the
#              current tag is an open or close tag.
# @return A string to replace the current tag with.
sub process_pre( \$$ ) {
    my $count = shift;
    my $lead  = shift; 
    my $cval;

    if($lead eq "/") {
        $cval = --$$count 
    } else {
        $cval = $$count++;
    }

    if($cval == 0) { 
        return sprintf("<%spre:%02d>", $lead, $cval);
    } else { 
        return sprintf("&lt;%spre&gt;", $lead);
    }

}


## @fn $ process_image($imagedata)
# Convert a wiki markup image tag to HTML. This will take the contents of a
# mediawiki image tag, without the leading [[(Image|File): or trailing ]] and
# produce an appropriate html image tag to replace it.
#
# @note This does not support all mediawiki options. Notably vertical alignment
#       is ignored, as are frame, border, and thumbnail options.
#
# @param imagedata A string containing the image markup to process.
# @return The generated img tag.
sub process_image {
    my $imagedata = shift;
    my $style = "border: none;";
    my $divstyle = "";
    my $linkurl  = "";

    # Pull out the name, and any options
    my ($name, $options) = $imagedata =~ /^([^|]+)(|.*)?$/;
    $options = "" if(!defined($options));

    # Simple part first - start the image tag
    my $image = "<img src=\"../../$mediadir/$name\"";

    # If we have any options, process them
    if($options) {
        $options =~ s/^\|//; # trim the leading |

        my @opts = split(/\|/, $options);

        foreach my $opt (@opts) {
            if($opt =~ /^none$/) {
                # do nothing
            } elsif($opt =~ /^left$/i) {
                $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
            } elsif($opt =~ /^right$/i) {        
                $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
            } elsif($opt =~/^center$/i) {
                $divstyle = ' style="width: 100%; text-align: center;"';
            } elsif($opt =~ /^alt=(.*)$/i) {
                $image .= " alt=\"$1\"";
            } elsif($opt =~ /^link=(.*)$/i) {
                $linkurl = $1;
            } elsif($opt =~ /^(\d+\s*px|\d+\s*x\s*\d+\s*px|border|frame|thumb|frameless|baseline|sub|super|top|text-top|middle|bottom|text-bottom|page=.*)$/i) {
                print "WARNING: Image processor is skipping unsupported option '$1' in $imagedata\n";
            # If we've checked all other options, just treat it as the caption
            } else {
                $image .= " title=\"$opt\"";
            }
        }
    }

    if($linkurl) {
        $image = "<a href=\"$linkurl\">$image /></a>";
    } else {
        $image .= " />";
    }

    return "<div$divstyle>$image</div>";
}


## @fn $ process_flash($args)
# Given the contents of a <flash></flash> tag, attempt to generate a suitable [anim] 
# tag to feed to the processor.
#
# @param args The argyments specified for the flash tag.
# @return A string containing the anim tag.
sub process_flash {
    my $args = shift;

    # Hash of the settings, please...
    my %opts = $args =~ /(\w+)\s*=\s*([^\|]+)/g;

    # Good old flash tags need that hideous embed/object malarky
    my ($embedargs, $objectargs) = ("", "");

    # Go through the args we have, and if it's acceptable, add it to the arg strings
    foreach my $arg (keys(%opts)) {
        if($flashargs{$arg}) {
            $embedargs .= ' '.$arg.' ="'.$opts{$arg}.'"' if($arg ne "id");
            $objectargs .= '<param name="'.$arg.'" value="'.$opts{$arg}.'" />' if($arg ne "name");
        }
    }

    # The url is the filename with the media directory prepended...
    my $url = "../../$mediadir/".$opts{"file"};
    
    # Append the flash args if we have them
    $url .= $opts{"flashvars"} if($opts{"flashvars"});
    
    return '<object classid="clsid:d27cdb6e-ae6d-11cf-96b8-444553540000"'.
           ' width="'.$opts{"width"}.'"'.
           ' height="'.$opts{"height"}.'"'.
           ' codebase="http://fpdownload.macromedia.com/pub/shockwave/cabs/flash/swflash.cab#version='.$flashversion.'">'.
           ' <param name="movie" value="'.$url.'">'.$objectargs. 
           ' <embed src="'.$url.'"'.
           ' width="'.$opts{"width"}.'"'.
           ' height="'.$opts{"height"}.'"'.$embedargs. 
           ' pluginspage="http://www.macromedia.com/shockwave/download/index.cgi?P1_Prod_Version=ShockwaveFlash"></embed></object>';
}


## @fn $ process_popup($args, $content)
# Generate the HTML required to show a popup with the specified settings and content in
# a page. This will create the span structure that will be automatically converted to a
# popup by the TWPopup javascript in the target course.
#
# @param args    The popup tag arguments.
# @param content The content of the popup. This will be converted to base64.
# @return A string containing the popup spans.
sub process_popup {
    my $args     = shift;
    my $content  = shift; 
    my $result   = '<span class="twpopup">';

    # Convert the args to hash. if needed
    my %hashargs = $args =~ /\s*(\w+)\s*=\s*"([^"]+)"/go;

    # Add the text shown in the page ("text" is needed to support direct conversion of [local])
    $result .= $hashargs{"title"} || $hashargs{"text"} || "popup";

    # Now we need to sort out the inner span. Start by working on the optional span title
    my $spantitle = "";
    $spantitle .= "xoff=".$hashargs{"xoff"}.";" if(defined($hashargs{"xoff"}));
    $spantitle .= "yoff=".$hashargs{"yoff"}.";" if(defined($hashargs{"yoff"}));
    $spantitle .= "hide=".$hashargs{"hide"}.";" if(defined($hashargs{"hide"}));
    $spantitle .= "show=".$hashargs{"show"}.";" if(defined($hashargs{"show"}));

    $result .= '<span class="twpopup-inner"';
    $result .= " title=\"$spantitle\"" if($spantitle);
    $result .= ">".encode_base64(encode("UTF-8", $content), '')."</span></span>";

    return $result;
}    


## @fn $ process_streamflv($wikih, $args, $name)
# Generate the HTML required to show a streamed video with the specified settings and 
# name. This will generate the html that will be automatically converted to a streamed
# video player by the flowplayer javascript in the target course.
#
# @param wikih The wiki API handle to issue requests through if needed.
# @param args  The streamflv tag arguments.
# @param name  The name of the stream file.
# @return A string containing the streamed video tags.
sub process_streamflv {
    my $wikih = shift;
    my $args  = shift;
    my $name  = shift;

    # Convert the args to hash. if needed
    my %hashargs = $args =~ /\s*(\w+)\s*=\s*"([^"]+)"/go;

    # Work out the link style string
    my $style = "display: block;";
    $style .= "width:".(defined($hashargs{"width"}) ? $hashargs{"width"} : 320)."px;";
    $style .= "height:".(defined($hashargs{"height"}) ? $hashargs{"height"} : 320)."px;";
   
    # If the name is not already a url, make it into one
    $name = get_media_url($wikih, $name) unless($name =~ m{^https?://});

    # Here we go...
    my $result = '<a href="'.$name.'" style="'.$style.'" class="streamplayer">';
    if(defined($hashargs{"splash"})) {
        # Ensure the splash has no namespace
        $hashargs{"splash"} =~ s/^(.*?)://;
        
        # get its dimensions, if possible
        my ($width, $height) = get_media_size($wikih, $hashargs{"splash"});

        # If we have the dimensions, insert the splash image
        $result .= '<img src="../../'.$mediadir.'/'.$hashargs{"splash"}.'" width="'.$width.'" height="'.$height.'" />';
    }
    $result .= "</a>";

    return $result;
}


## @fn $ process_source($args, $source, $id)
# Process a <source> tag, converting it into a <pre> block with associated stylesheet to
# provide highlighting.
#
# @param args   The arguments to the source element. Must contain lang and style at least.
# @param source The body of the source element, containing the source to highlight.
# @param id     The page-wide unique id for this source.
# @return A string containing the highlighed source.
sub process_source {
    my $args   = shift;
    my $source = shift;
    my $id     = shift;

    # Convert the args to hash. if needed
    my %hashargs = $args =~ /\s*(\w+)\s*=\s*"([^"]+)"/go;

    return highlight_fragment($id, \%hashargs, $source);
}


## @fn $ process_entities_html($wikih, $text)
# Process the entities in the specified text, allowing through only approved tags, and
# convert wiki markup to html.
#
# @note From v1.7 on this function does no recursively process transclusions, as all 
#       transclusion processing has been moved into wiki_fetch. 
#     
# @todo improve   implementation and coverage of mediawiki markup
# @param wikih    The wiki API handle to issue requests through if needed.
# @param text     The text to process.
# @return The processed text.
sub process_entities_html {
    my $wikih    = shift;
    my $text     = shift;

    # Undo XML::Simple's meddling
    $text =~ s{<}{&lt;}go;
    $text =~ s{>}{&gt;}go;
    
    # Nuke spaces on lines with nothing else
    $text =~ s{\n\s*?\n}{\n\n}go;
    
    # Trim leading and trailing space
    $text =~ s/^\s*//;
    $text =~ s/\s*$//;

    # Mark the first level of potential pres
    my $count = 0;
    $text =~ s{&lt;(/?)pre&gt;}{process_pre($count, $1)}eig;
    
    # pull out the pre contents, and then nuke them
    my @prebodies = $text =~ m{<pre:00.*?>(.*?)</pre:00.*?>}gios;
    $count = 0;
    $text =~ s{(<pre:00.*?>).*?(</pre:00.*?>)}{sprintf("%s:marker%02d:%s", $1, $count++, $2)}gies;

    # Now fix up approved tags
    foreach my $tag (@approved_html) {
        $text =~ s{&lt;(/?\s*$tag.*?)&gt;}{<$1>}gis;
    }

    # Basic tags
    $text =~ s{'''''(.*?)'''''}{<strong><i>$1</i></strong>}gso;
    $text =~ s{'''(.*?)'''}{<strong>$1</strong>}gso;
    $text =~ s{''(.*?)''}{<i>$1</i>}gso;
    $text =~ s{===(.*?)===}{<h3>$1</h3>}gso;
    $text =~ s{====(.*?)====}{<h4>$1</h4>}gso;

    # Maths tags - convert straight to latex tags
    $text =~ s{<math>(.*?)</math>}{[latex]\$$1\$[/latex]}gso;

    # bullet lists
    $text =~ s{^(\*\s*.*?)(?=\n\s*?\n|^\#|\z)}{process_list($1, '*', '<ul>', '</ul>')}gmse;
    $text =~ s{^(\#\s*.*?)(?=\n\s*?\n|^\*|\z)}{process_list($1, '#', '<ol>', '</ol>')}gmse;

    # Definition lists
    $text =~ s{^([:;].*?)(?=^[^:;]|\z)}{process_deflist($1)}gmse;

    # Images
    $text =~ s{\[\[(?:File|Image):(.*?)\]\]}{process_image($1)}ges;

    # Flash to anim tag
    $text =~ s{<flash>(.*?)</flash>}{process_flash($1)}ges;

    # Streamed video
    $text =~ s{<streamflv\s*(.*?)>(.*?)</streamflv>}{process_streamflv($1, $2)}gmse;

    # <source>
    my $sid = 0;
    $text =~ s{<source\s*(.*?)>(.*?)</source}{process_source($1, $2, ++$sid)}gmse;

    # External links
    $text =~ s{\[((?:http|https|ftp|mailto):[^\s\]]+)(?:\s*([^\]]+))?\]}{<a href="$1">$2</a>}gs;

    # Paragraph fixups
    $text =~ s{([^>])\n\n}{$1</p>\n\n}go;
    $text =~ s{\n\n(?!<(p|ta|ul|ol|div|h|blockquote|dl))}{\n\n<p>}go;
    $text =~ s{^\s*([^<])}{<p>$1}o;
    $text =~ s{([^>])\s*$}{$1</p>}o;

    # pre processing...
    for($count = 0; $count < scalar(@prebodies); ++$count) {
        # And replace the pre in the text
        my $target = sprintf("<pre:00>:marker%02d:</pre:00>", $count);
        $text =~ s{$target}{"<pre>".$prebodies[$count]."</pre>"}ge;
    }

    # Popups - convert to html
    $text =~ s{\[local\s*(.*?)\](.*?)[/local]}{process_popup($1, $2)}gmse;
    $text =~ s{<popup\s*(.*?)>(.*?)</popup>}{process_popup($1, $2)}gmse;

    return $text;
}


# -----------------------------------------------------------------------------
#  Basic wiki interaction

## @fn $ wiki_login($wikih, $username, $password)
# Attempt to log into the wiki identified by the provided wiki API handle.
# This will log the handle provided into the wiki using the credentials
# specified in the arguments.
#
# @param wikih    A reference to a MediaWiki API object.
# @param username The name of the user to log in as.
# @param password The password for the specified user.
# @return true on success. This will die internally if the login fails, so
#         it will only return on success.
sub wiki_login {
    my $wikih    = shift;
    my $username = shift;
    my $password = shift;

    $wikih -> login({ lgname     => $username, 
                      lgpassword => $password })
        or die "ERROR: Unable to log into the wiki. Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    return 1;
}


## @fn $ wiki_fetch($wikih, $pagename, $transclude, $path, $level, $maxlevel)
# Attempt to obtain the contents of the specified wiki page, optionally doing
# page transclusion on the content.
#
# @param wikih      A reference to a MediaWiki API object.
# @param pagename   The title of the page to fetch.
# @param transclude Enable transclusion of fetched pages.
# @param path       A string containing the recursion path.
# @param level      The current recursion level.
# @param maxlevel   The level at which recursion halts.
# @return A string containing the page data.
sub wiki_fetch {
    my $wikih      = shift;
    my $pagename   = shift;
    my $transclude = shift;
    my $path       = shift;
    my $level      = shift;
    my $maxlevel   = shift;

    $level    = 0        if(!defined($level));
    $maxlevel = MAXLEVEL if(!defined($maxlevel));
    $path     = ""       if(!defined($path));

    # Check for recursion level overflow, fall over if we hit the limit
    die "ERROR: Maximum level of allowed recursion ($maxlevel levels) reached while fetching page content.\nRecursion path is: $path\n"
        if($level >= $maxlevel);

    # First attempt to get the page
    my $page = $wikih -> get_page({ title => $pagename } )
        or die "ERROR: Unable to fetch page '$pagename'. Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Do we have any content? If not, return an error...
    die "ERROR: $pagename page is missing!\n" if($page -> {"missing"});

    my $content = $page -> {"*"};

    # Return right here if we are not transcluding, no point doing more work than we need.
    return $content if(!$transclude || !$content);

    # Break any transclusions inside <nowiki></nowiki>
    while($content =~ s|(<nowiki>.*?)\{\{([^<]+?)\}\}(.*?</nowiki>)|$1\{\(\{$2\}\)\}$3|is) { };

    # recursively process any remaining transclusions
    $content =~ s/\{\{(.*?)\}\}/wiki_fetch($wikih, $1, 1, "$path -> $1", $level + 1, $maxlevel)/ges; 

    # revert the breakage we did above
    while($content =~ s|(<nowiki>.*?)\{\(\{([^<]+?)\}\)\}(.*?</nowiki>)|$1\{\{$2\}\}$3|is) { };

    # We should be able to return the page now
    return $content;
}


## @fn $ wiki_course_exists($wikih, $nspace)
# Determine whether the specified namespace contains the required Course and
# CourseData pages. If the CourseData page exists, this returns the content
# of the page, otherwise it returns undef. Note that the 'Course' page name
# is case sensitive, the CourseData page name case is determined from the
# link in the course page.
#
# @param wikih  A reference to a MediaWiki API object.
# @param nspace The namespace containing the course.
# @return A string containing the couresdata page 
sub wiki_course_exists {
    my $wikih  = shift;
    my $nspace = shift;

    # First, get the course page
    my $course = $wikih -> get_page({ title => "$nspace:Course" } )
        or die "ERROR: Unable to fetch $nspace:Course page. Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Is the course page present?
    die "ERROR: $nspace:Course page is missing!\n" if(!$course -> {"*"});

    # Do we have a coursedata link in the page?
    my ($cdlink) = $course -> {"*"} =~ /\[\[($nspace:coursedata)\|.*?\]\]/i;

    # Bomb if we have no coursedata link
    die "ERROR: $nspace:Course page does not contain a CourseData link.\n"
        if(!$cdlink);

    # Fetch the linked page
    my $coursedata = $wikih -> get_page({ title => $cdlink })
        or die "ERROR: Unable to fetch coursedata page ($cdlink). Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Do we have any content? If not, return an error...
    die "ERROR: $cdlink page is missing!\n" if($coursedata -> {"missing"});
    die "ERROR: $cdlink page is empty!\n" if(!$coursedata -> {"*"});

    # Get here and we have a coursedata page with some content, return the full thing
    return wiki_fetch($wikih, $cdlink, 1);
}


## @fn $ get_media_url($wikih, $title)
# Attempt to obtain the URL of the media file with the given title. This will assume
# the media file can be accessed via the Image: namespace, and any namespace given
# will be stripped before making the query
#
# @param wikih A reference to a MediaWiki API object.
# @param title The title of the media file to obtain the URL for
# @return The URL to the media file, or undef if it can not be located.
sub get_media_url {
    my $wikih = shift;
    my $title = shift;

    # strip any existing namespace, if any
    $title =~ s/^.*?://;

    # Ask for the image information for this file
    return undef unless my $ref = $wikih -> api({ "action" => 'query',
                                                  "titles" => "Image:$title",
                                                  "prop"   => 'imageinfo',
                                                  "iiprop" => 'url' } );

    # get the page id and the page hashref with title and revisions
    my ($pageid, $pageref) = each %{ $ref -> {"query"} -> {"pages"} };

    # if the page is missing then return an empty string
    return '' if(defined($pageref -> {"missing"}));

    my $url = @{$pageref -> {"imageinfo"}}[0] -> {"url"};

    # Handle relative paths 'properly'...
    unless($url =~ /^http\:\/\//) {
        if(!$wikih -> {"config"} -> {"files_url"}) {
            print "ERROR: The API returned a relative path for the URL for '$title'. You must provide a value for the fileurl argument and try again.\n";
            return undef;
        }
        $url = $wikih -> {"config"} -> {"files_url"}.$url;
    }

    return $url;
}


## @fn @ get_media_size($wikih, $title)
# Attempt to obtain the width and height of the media file with the given title. 
# This will assume the media file can be accessed via the Image: namespace, and 
# any namespace given will be stripped before making the query
#
# @param wikih A reference to a MediaWiki API object.
# @param title The title of the media file to obtain the URL for
# @return The width and height of the media, or undef if they can not be obtained.
sub get_media_size {
    my $wikih = shift;
    my $title = shift;

    # strip any existing namespace, if any
    $title =~ s/^.*?://;

    # Ask for the image information for this file
    return undef unless my $ref = $wikih -> api({ "action" => 'query',
                                                  "titles" => "Image:$title",
                                                  "prop"   => 'imageinfo',
                                                  "iiprop" => 'size' } );

    # get the page id and the page hashref with title and revisions
    my ($pageid, $pageref) = each %{ $ref -> {"query"} -> {"pages"} };

    # if the page is missing then return an empty string
    return '' if(defined($pageref -> {"missing"}));

    my $width  = @{$pageref -> {"imageinfo"}}[0] -> {"width"};
    my $height = @{$pageref -> {"imageinfo"}}[0] -> {"height"};

    # If both are zero, assume they are unobtainable
    return (undef, undef) if(!$width && !$height);

    # Otherwise return what we've got
    return ($width, $height);
}


# -----------------------------------------------------------------------------
#  Metadata handling

## @fn $ metadata_find($page, $title)
# Attempt to extract the contents of a metadata block from the specified page.
# This will search for the == Metadata == marker in the specified page content, and
# attempt to extract any metadata enclosed in <pre> or <source> tags within the 
# section following the marker.
#
# @param page  The content of the page to extract metadata from.
# @oaram title The title of the page.
# @return undef if no metadata is found, otherwise the metadata XML.
sub metadata_find {
    my $page  = shift;
    my $title = shift;

    print "NOTE: Extracting metadata xml from $title...\n";

    # We have a page, can we pull the metadata out?
    my ($metadata) = $page =~ m{==\s*Metadata\s*==\s*<pre>\s*(.*?)\s*</pre>}ios;
    
    # Do we have metadata? If not, try again with <source> instead of <pre>
    # Yes, we could do this in one regexp above, but
    ($metadata) = $page =~ m{==\s*Metadata\s*==\s*<source.*?>\s*(.*?)\s*</source>}ios
        if(!$metadata);

    # return whatever we may have now...
    return $metadata;
}


## @fn $ metadata_find_module($metadata, $title)
# Given a metadata hashref and a module title, attempt to locate a module name
# that contains the title.
#
# @param metadata A reference to a hash containing the parsed metadata xml.
# @param title    The title of the module to locate in the metadata.
# @return The module name if found, undef if the module can not be located.
sub metadata_find_module {
    my $metadata = shift;
    my $title    = shift;

    foreach my $name (keys(%{$metadata -> {"module"}})) {
        if($metadata -> {"module"} -> {$name} -> {"title"} eq $title) {
            # Check that the name does not contain spaces...
            if($name =~ /\s/) {
                print "ERROR: name element for module $title contains spaces. This is not permitted.\n";
                return undef;
            }
            return $name;
        }
    }

    return undef;
}


## @fn $ metadata_save($metadata, $outdir)
# Save the provided metadata to the metadata.xml file in the specified directory.
# This assumes that the contents of metadata is a string containing xml data.
#
# @param metadata The metadata to save.
# @param outdir   The directory to save the metadata in.
sub metadata_save {
    my $metadata = shift;
    my $outdir   = shift;

    open(MDATA, ">", path_join($outdir, "metadata.xml"))
        or die "ERROR: Unable to write metadata to $outdir: $!\n";
    
    print MDATA "<?xml version='1.0' standalone='yes'?>\n$metadata\n";
    
    close(MDATA);
}


## @fn void course_metadata_save($coursepage, $destdir)
# Extract the course metadata from the specified course page, and save it to
# the course data directory.
#
# @param coursepage The content of the page to extract the metadata from.
# @param destdir    The directory to write the metadata.xml file to.
sub course_metadata_save {
    my $coursepage = shift;
    my $destdir    = shift;

    # Try to pull out the metadata
    my $metadata = metadata_find($coursepage, "course data page");

    die "ERROR: Unable to locate course metadata in the course data page.\n"
        if(!$metadata);

    # We have metadata, so save it
    metadata_save($metadata, $destdir);
}


# -----------------------------------------------------------------------------
#  Module export

## @fn $ wiki_export_module($wikih, $module, $moduledir, $convert, $markers)
# Export the specified module to the module directory, splitting the steps into
# separate files inside the directory. This determines whether the module dir
# exists and, if it does not, it creates it, then it tries to save the module
# into it as separate steps.
#
# @param wikih     A reference to a MediaWiki API object.
# @param module    The name of the module to export, including namespace
# @param moduledir The directory to write the module data to.
# @param convert   If true, step contents are converted from wiki markup to html.
# @param markers   A reference to a hash to store marker information in.
# @return true if the module was saved, false if there was a problem
sub wiki_export_module {
    my $wikih     = shift;
    my $module    = shift;
    my $moduledir = shift;
    my $convert   = shift;
    my $markers   = shift;

    print "NOTE: Exporting module $module to $moduledir.\n";

    # Sort out the directory
    if(makedir($moduledir)) {
        my $mpage = wiki_fetch($wikih, $module, 1);

        # Do we have any content? If not, bomb now
        if($mpage) {

            # Mark the == title == a little more reliably
            $mpage =~ s/^==([^=].*?)==/--==$1==/gm;

            my @steps = split("--==", $mpage);

            if(scalar(@steps)) {
                my $stepnum = 0;

                foreach my $step (@steps) {
                    if($step) {
                        my ($title, $body) = $step =~ m{^\s*(.*?)\s*==\s*(.*)$}iso;

                        # If we have a title and body, we need to write the text out as html
                        if($title && $body) {
                            my $stepname = path_join($moduledir, sprintf("step%02d.html", ++$stepnum));

                            if($convert) {
                                print "NOTE: Converting mediawiki markup in $stepname to html.\n";
                                $body = process_entities_html($wikih, $body, $title);
                            }

                            open(STEP, "> $stepname")
                                or die "ERROR: Unable to open $stepname ($title) for writing: $!\n";

                            binmode STEP, ':utf8'; 

                            # Print the html in minimal 'new style' for the processor
                            print STEP "<html>\n<head>\n<title>$title</title>\n</head><body><div id=\"content\">\n$body\n</div><!-- id=\"content\" -->\n</body>\n</html>\n";
                            close(STEP);
                           
                            # Locate and record any markers
                            my @marklist = $body =~ /(.{0,16}\?\s*\?\s*\??.{0,56})/go;
                            $markers -> {"$stepname"} = \@marklist
                                if(scalar(@marklist));

                        # Otherwise, work out where the problem was...
                        } else {
                            if(!$title && $body) {
                                print "ERROR: Unable to parse title from\n$step\n";
                            } elsif($title && !$body) {
                                print "ERROR: Unable to parse body from\n$step\n";
                            } else {
                                print "ERROR: Unable to parse anything from\n$step\n";
                            }
                        }
                    }
                }
            } else { # if(scalar(@steps)) {
                print "ERROR: Unable to parse steps from content of $module.\n";
            }


        } else { # if($mpage) {
            print "WARNING: No content for $module.\n";
        }
    } # if(makedir($moduledir)) {
    
    return 0;
}


## @fn $ wiki_export_modules($wikih, $themepage, $themedir, $metadata, $convert, $markers)
# Export the modules listed in the supplied theme page to the specified
# data directory.
#
# @param wikih     A reference to a MediaWiki API object.
# @param themepage The text of the theme page
# @param themedir  The base output directory.
# @param metadata  The theme metadata, needed for module dir naming.
# @param convert   If true, step contents are converted from wiki markup to html.
# @param markers   A reference to a hash to store marker information in.
# @return The number of modules exported, or -1 on error.
sub wiki_export_modules {
    my $wikih     = shift;
    my $themepage = shift;
    my $themedir  = shift;
    my $metadata  = shift;
    my $convert   = shift;
    my $markers   = shift;

    print "NOTE: Parsing module names from theme page...\n";

    # parse out the list of modules first
    my ($names) = $themepage =~ m{==\s*Modules\s*==\s*(.*?)\s*==}ios;

    # Die if we have no modules
    if(!$names) {
        print "ERROR: Unable to parse module names from theme page.\n";
        return -1;
    }

    # Split the names up
    my @modules = $names =~ m{^\s*\[\[(.*?)\]\]}gim;
    
    my $count = 0;

    # Process each module
    foreach my $module (@modules) {
        # We need the module name without the namespace
        my ($truename) = $module =~ m{^\w+:(.*)$}o;

        if($truename) {
            # Now, do we have a matching module in the metadata?
            my $dirname = metadata_find_module($metadata, $truename);
            if($dirname) {
                my $modulepath = path_join($themedir, $dirname);

                # Export the contents of the module if possible
                wiki_export_module($wikih, $module, $modulepath, $convert, $markers);

            } else {
                print "ERROR: Unable to locate metadata entry for $truename. (Remember, the module name without namespace MUST match the metadata title!)\n";
            }
        } else {
            print "ERROR: Unable to remove namespace from $module.\n";
        }
    }

    return $count;
}


# -----------------------------------------------------------------------------
#  Theme export

## @fn $ wik_export_theme($wikih, $theme, $basedir, $convert, $markers)
# Export the specified theme to the output directory. This determine whether
# the theme exists and, if it does, extract the metadata and module list from
# the page, and then use that information to create the theme directory and
# export the modules.
#
# @param wikih   A reference to a MediaWiki API object.
# @param theme   The name of the theme to export, including namespace
# @param basedir The base output directory.
# @param convert If true, step contents are converted from wiki markup to html.
# @param markers A reference to a hash to store marker information in.
# @return true if the theme was exported successfully, false otherwise
sub wiki_export_theme {
    my $wikih   = shift;
    my $theme   = shift;
    my $basedir = shift;
    my $convert = shift;
    my $markers = shift;
 
    print "NOTE: Fetching page data for $theme...\n";

    # Okay, does the theme page exist?
    my $tpage = wiki_fetch($wikih, $theme, 1);

    # Do we have any content? If not, bomb now
    if(!$tpage) {
        print "WARNING: No content for $theme.\n";
        return 0;
    }

    # Attempt to obtain the metadata for the theme, if we can't then This is Not Good - we need that 
    # information to do, well, anything.
    my $metadata = metadata_find($tpage);
    if(!$metadata) {
        print "ERROR: Unable to parse metadata from $theme. Unable to process theme.\n";
        return 0;
    }

    print "NOTE: Parsing metadata information to determine directory structure...\n";
    
    # Parse the metadata into a useful format
    my $mdxml = XMLin($metadata);
    
    # Did the parse work?
    if($mdxml) {

        # Do we have the required fields (name, really, at this point)
        if($mdxml -> {"name"}) {
            
            # The name Must Not Contain Spaces or we're full of woe and pain
            if($mdxml -> {"name"} !~ /\s/) {
                
                # Okay, we have something we can work with - create the theme directory
                my $themedir = path_join($basedir, $mdxml -> {"name"});

                print "NOTE: Creating theme directory ",$mdxml -> {"name"}," for $theme...\n";
                if(makedir($themedir)) {

                    # We have the theme directory, now we need to start on modules!
                    wiki_export_modules($wikih, $tpage, $themedir, $mdxml, $convert, $markers);

                    # Modules are processed, try saving the metadata
                    metadata_save($metadata, $themedir);

                    return 1;
                } 
            } else { # if($mdxml -> {"name"} !~ /\s/) {
                print "ERROR: name element for $theme contains spaces. This is not permitted.\n";            
            }
        } else { # if(!$mdxml -> {"name"}) {
            print "ERROR: metadata element does not have a name attribute. Unable to save theme.\n";
        }
    } else { # if($mdxml) {
        print "ERROR: Unable to parse metadata. Check the metadata format and try again.\n";
    }
    
    return 0;
}


## @fn $ wiki_export_themes($wikih, $cdpage, $basedir, $convert, $markers)
# Export the themes listed in the supplied coursedata page to the specified
# data directory.
#
# @param wikih   A reference to a MediaWiki API object.
# @param cdpage  The text of the coursedata page
# @param basedir The base output directory.
# @param convert If true, step contents are converted from wiki markup to html.
# @param markers A reference to a hash to store marker information in.
# @return  The number of themes exported, or -1 on error.
sub wiki_export_themes {
    my $wikih   = shift;
    my $cdpage  = shift;
    my $basedir = shift;
    my $convert = shift;
    my $markers = shift;

    print "NOTE: Parsing theme names from course data page...\n";

    # parse out the list of themes first
    my ($names) = $cdpage =~ m{==\s*Themes\s*==\s*(.*?)\s*==}ios;

    # Die if we have no themes
    if(!$names) {
        print "ERROR: Unable to parse theme names from course data page.\n";
        return -1;
    }

    # Split the names up
    my @themes = $names =~ m{^\s*\[\[(.*?)\]\]}gim;
    
    my $count = 0;
    # Process each theme
    foreach my $theme (@themes) {
        ++$count if(wiki_export_theme($wikih, $theme, $basedir, $convert, $markers));
    }

    return $count;
}


# -----------------------------------------------------------------------------
#  File export


## @fn $ wiki_export_files($wikih, $listpage, $destdir)
# Attempt to download all the files listed on the specified list page into the
# destination directory.
#
# @param wikih    A reference to a MediaWiki API object.
# @param listpage A page containing a list of [[File: or [[Image: links
# @param destdir  The directory to save files to, will be created if needed.
# @return The number of files downloaded.
sub wiki_export_files {
    my $wikih      = shift;
    my $listpage   = shift;
    my $destdir    = shift;

    # We need the page to start with
    my $list = wiki_fetch($wikih, $listpage, 1)
        or die "ERROR: Unable to fetch $listpage page. Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";
    
    # Do we have any content? If not, bomb now
    if(!$list) {
        print "WARNING: No content for $listpage.\n";
        return 0;
    }

    if(makedir($destdir)) {        
        # Now we can do a quick and dirty yoink on the file/image links
        my @entries = $list -> {"*"} =~ m{\[\[((?:Image:|File:)[^|\]]+)}goi;
        
        if(scalar(@entries)) {
            print "NOTE: $listpage shows ",scalar(@entries)," files to download. Processing...\n";
            
            my $writecount = 0;
            my $file;
            foreach my $entry (@entries) {
                # First, we need to remove spaces
                $entry =~ s/ /_/g;
                
                # Work out the filename
                my ($name) = $entry =~ /^(?:Image|File):(.*)$/io;
                
                if($name) {
                    my $filename = path_join($destdir, $name);
 
                    print "NOTE: Downloading $entry... ";
                   
                    # Now we can begin the download
                    if($file = $wikih -> download({ title => $entry})) {
                    
                        print "writing to $filename... ";
                        # We now have data, so we need to save it.
                        open(DATFILE, ">", $filename)
                            or die "\nERROR: Unable to save $filename: $!\n";
                        
                        binmode DATFILE;
                        print DATFILE $file;
                        
                        close(DATFILE);
                    
                        print "done.\n";
                        ++$writecount;
                    } else {
                        print "\nERROR: Unable to fetch $entry. Error from the API was:\n".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";
                    }
                } else {
                    print "ERROR: Unable to determine filename from $entry.\n";
                }
            }

            return $writecount;
        } else {
            print "NOTE: No files or images listed on $listpage. Nothing to do here.\n";
        }
    } else {
        print "ERROR: Unable to create directory $destdir: $@\n";
    }

    return 0;
}
    

# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

print "wiki2course.pl version ",VERSION," started.\n";

# Process the command line
GetOptions('outputdir|o=s' => \$basedir,
           'username|u=s'  => \$username,
           'password|p=s'  => \$password,
           'mediadir|m=s'  => \$mediadir,
           'namespace|n=s' => \$namespace,
           'fileurl|f=s'   => \$fileurl,
           'wiki|w=s'      => \$apiurl,
           'convert|c=s'   => \$convert,
           'verbose|v'     => \$verbose,
           'help|?|h'      => \$help, 
           'man'           => \$man) or pod2usage(2);
if(!$help && !$man) {
    print STDERR "No username specified.\n" if(!$username);
    print STDERR "No output directory specified.\n" if(!$basedir);
}
pod2usage(-verbose => 2) if($man);
pod2usage(-verbose => 0) if($help || !$username);


# If convert hasn't been explicitly specified, enable it
if($convert eq '') {
    $convert = 1;
} else {
    # handle other converts
    $convert = 1
        if($convert =~ /^y(es)?/i || $convert =~ /^on$/i);
}

# If we don't have a password, prompt for it
$password = get_password() if(!$password);

# Now we need to process the output directory. Does it exist?
if(makedir($basedir)) {
    # Get the show on the road...
    my $wikih = MediaWiki::API -> new({api_url => $apiurl });

    # Set the file url if needed
    $wikih -> {"config"} -> {"files_url"} = $fileurl if($fileurl);

    # Now we need to get logged in so we can get anywhere
    wiki_login($wikih, $username, $password);

    # Get the coursedata page
    my $cdpage = wiki_course_exists($wikih, $namespace);

    # Bomb if we don't have a hashref
    die $cdpage if(!ref($cdpage));

    # Pull down the text data first
    wiki_export_themes($wikih, $cdpage -> {"*"}, $basedir, $convert, $markers);

    # save course metadata
    course_metadata_save($cdpage -> {"*"}, $basedir);

    # Write out images and animations
    wiki_export_files($wikih, "$namespace:Media", path_join($basedir, $mediadir));

    # Print out any markers
    foreach my $step (sort keys(%$markers)) {
        print "NOTE: Found the following markers in $step:\n";
        foreach my $marker (@{$markers -> {$step}}) {
            print "    ...$marker...\n";
        }
        print "\n";
    }
}
 
   
# THE END!
__END__

=head1 NAME

wiki2course - generate a course data directory from a wiki namespace.

=head1 SYNOPSIS

backuplj [options]

 Options:
    -c, --convert=MODE       convert mediawiki markup to html (default: on)
    -f, --fileurl=URL        the location of the wiki.
    -h, -?, --help           brief help message.
    --man                    full documentation.
    -m, --mediadir=DIR       the subdir into which media should be written.
    -n, --namespace=NAME     the namespace containing the course to export.
    -o, --outputdir=DIR      the name of the directory to write to.
    -p, --password=PASSWORD  password to provide when logging in. If this is
                             not provided, it will be requested at runtime.
    -u, --username=NAME      the name to log into the wiki as.
    -v, --verbose            if specified, produce more progress output.
    -w, --wiki=APIURL        the url of the mediawiki API to use.

=head1 OPTIONS

=over 8

=item B<-c, convert>

If set to 'yes', 'on', or '1' then medaiwiki markup in the exported data will
be converted to html. If set to any other value, conversion will not be done.
Note that the default is to process markup to html.

=item B<-f, fileurl>

This argument is optional. If provided, the script will use the specified URL
as the base location for wiki files. This option is unlikely to be of use to 
users of the APE wikis.

=item B<-h, -?, --help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<-m, --mediadir>

This argument is optional. This argument allows you to specify the name of the
directory in the generated coursedata directory to which media files (images, 
animations, and so on) will be written. If provided it overrides the default 
"media" directory. Note that this is relative to the directory specified with
the --outputdir option.

=item B<-n, --namespace>

I<This argument must be provided.> This argument identifies the namespace 
containing the course you want to export, and it must correspond to a valid 
namespace in the wiki. As ever, case is important here, so triple-check that 
you have provided the namespace name in the correct case.

=item B<-o, --outputdir>

I<This argument must be provided.> This specifies the name of the directory 
into which the course should be exported. If the specified directory does not 
exist, the script will attempt to create it for you. Note that if the 
directory I<does> exist, the script will simply export the course into the 
directory, overwriting any files that may be present already!

=item B<--password>

This argument is optional. If provided, the script will attempt to use the 
specified password when logging into the wiki. Use of this argument is 
B<very strongly discouraged in general use> - it is provided to allow the 
export script to be called programmatically, and providing your password this 
way can be a security risk (anyone looking over your shoulder could see the 
plain text password on the command prompt, and the whole command line will be 
saved in your shell history, including the password).

=item B<-u, --username>

I<This argument must be provided.> This argument specifies which username 
should be used to log into the wiki. This must correspond to a valid wiki 
user, and you will need to either provide the password using the --password 
option described above, or you will be prompted to enter the password by 
wiki2course.pl. If your username contains spaces, please ensure that you 
either enclose the username in quotes, or replace any spaces with 
underscores. Note that wiki usernames B<are case sensitive>, so check that 
you use the correct case when specifying your username or the login will fail.

=head1 DESCRIPTION

Please consult the Docs:wiki2course.pl documentation in the wiki for a full
description of this program.

=cut

