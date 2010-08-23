package HTMLOutputHandler;

# Generate HTML course trees from intermediate format files.

# @copy 2008, Chris Page &lt;chris@starforge.co.uk&gt;
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

# All plugins must implement the following functions:
#
# get_type        - return "input" or "output"  
# get_description - return a human-readable description of the module 
# new             - return an instance of the module object
# use_plugin      - returns true if th eplugin can be used on the tree, false if not
# process         - actually does the processing.

require 5.005;
use Data::Dumper;
use Cwd qw(getcwd chdir);
use Utils qw(load_complex_template check_directory fix_entities text_to_html resolve_path load_file log_print blargh lead_zero);
use Carp qw(confess);
use strict;

#uncomment for stacktrace on die
$SIG{__DIE__} = \&confess;

my ($VERSION, $type, $errstr, $htype, $desc, $liststore, $cbtversion, $tidyopts, $tidybin, $debug);

BEGIN {
	$VERSION       = 1.1;
    $htype         = 'output';                                       # handler type - either input or output
    $desc          = 'HTML CBT output processor, new format output'; # Human-readable name
	$errstr        = '';                                             # global error string
    $tidyopts      = '-i -w 0 -b -q -c -asxhtml --join-classes no --join-styles no --merge-divs no'; # parameters passed to htmltidy
    $tidybin       = '/usr/bin/tidy';                                # Location of htmltidy
    $cbtversion    = "";                                             # If a version prefix is needed, change this.
    $Data::Dumper::Purity = 1;
}

# ============================================================================
#  Constructor and identifier functions.  
#   
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self     = {
        "verbose" => 0, # set to 1 to enable additional output
        "tidy"    => 0, # set to 0 to disable htmltidy postprocessing
        "debug"   => 0, # set to 1 to retain intermediate files.
        @_
    };

    return bless $self, $class;
}

# Top level handler type ID
sub get_type { return $htype };

# Handler descriptive text
sub get_description { return $desc };

# Handler version number
sub get_version { return $VERSION };


# ============================================================================
#  Utility Code
#   

# Given a step name, this returns a string containing the canonical name for
# the step (eg: "node5.htm" => "step5.html")
sub get_step_name {
    my $filename = shift;

    my ($stepid) = $filename =~ /^\D+(\d+(.\d+)?).html?$/;
    die "FATAL: Unable to obtain stepid from $filename. This Should Not Happen!" if(!$stepid);

    $stepid = "0$stepid" if((0 + $stepid) < 10 && $stepid !~ /^0/);
    return "step".$stepid.".html";
}


# returns the maximum stepid in the specified array of step names
sub get_maximum_stepid {
    my $namesref = shift;

    my $maxid = 0;
    foreach my $name (@$namesref) {
        if($name =~ /^\D+(\d+(.\d+)?).html?$/o) {
            $maxid = $1 if($1 > $maxid);
        }
    }
}


# ============================================================================
#  Precheck - can this plugin be applied to the source tree?
#   

# This plugin can always be run against a tree, so we use the use check to ensure that
# the templates are available. This should die if the templates are not avilable, rather
# than return 0.
sub use_plugin {
    my $self    = shift;
    my $srcdir  = shift;
    $self -> {"templatebase"} = shift;
    my $plugins = shift;

    # prepend the processor template directory if the template is not absolute
    $self -> {"templatebase"} = $self -> {"path"}."/templates/".$self -> {"templatebase"} if($self -> {"templatebase"} !~ /^\//);
    $self -> {"templatebase"} = resolve_path($self -> {"templatebase"});

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Using template directory : ".$self -> {"templatebase"});
    die "FATAL: No templates found" if(!$self -> {"templatebase"});

    check_directory($self -> {"templatebase"}, "template directory");

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @themes = grep(!/^\./, readdir(SRCDIR));
    
    foreach my $theme (@themes) {
        my $fulltheme = "$srcdir/$theme"; # prepend the source directory
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Validating $theme metadata");

        die "FATAL: Metatadata validation failure. Halting" if(!$self -> load_metadata($fulltheme, 1, $plugins));
    }

    # if we get here, we can guarantee to be able to use the plugin.
    return 1;
}




# ============================================================================

# Load a version number from the global version file and append the current time
# and date
sub preload_version {
    my $self = shift;
    my $basedir = shift;

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Loading version");

    if(open(VERSFILE, "$basedir/version.txt")) {
        $self -> {"cbtversion"} = <VERSFILE>;
        chomp($self -> {"cbtversion"});
        close(VERSFILE);
    } else {
        blargh("Unable to open version file $basedir/version: $!");
        $self -> {"cbtversion"} .= "unknown";
    }

    my @stamp = localtime();
    my $date = sprintf "%d/%d/%d %d:%d:%d", $stamp[3], 1 + $stamp[4], 1900 + $stamp[5], $stamp[2], $stamp[1], $stamp[0]; 
    $self -> {"cbtversion"} .= " ($date)";

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Version is '".$self -> {"cbtversion"}."'");

}


# load a file containing tags to insert into the output html headers.
sub preload_header_include {
    my $self    = shift;
    my $basedir = shift;

    if(-e "$basedir/headerinclude.txt") {
        return load_file("$basedir/headerinclude.txt") || "";
    }

    return "";
}


# ============================================================================
#  Tag conversion code.
#  
 
## @method $ convert_term($termname)
# Convert a glossary term marker into a html glossary link. This uses the provided
# term name to derermine which glossary page and anchor to link the user to.
#
# @param termname The name of the term to link to.
# @return A string containing a html link to the appropriate glossary page and entry.
sub convert_term {
    my $self = shift;
    my $termname = shift;

    # ensure the term is lowercase
    my $key = lc($termname);

    $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # We need the first character of the term for the index link
    my $first = lc(substr($termname, 0, 1));

    # replace the contents of $first for digits and symbols
    if($first =~ /^[a-z]$/) {
        # do nothing...
    } elsif($first =~ /^\d$/) {
        $first = "digit";
    } else {
        $first = "symb";
    }

    # Build and return a glossary link
    return load_complex_template($self -> {"templatebase"}."/theme/module/glossary_link.tem",
                                 { "***letter***" => $first,
                                   "***term***"   => $key,
                                   "***name***"   => $termname });
}


## @method $ convert_image($tagdata)
# Convert an image tag to html markup. This processes the specified list of tag args
# and generates an appropriate html image element, or an error message to include
# in the document.
#
# @param tagdata  The image tag attribute list
# @return The string to replace the image tag with - either a html image element,
#         or an error message.
sub convert_image {
    my $self     = shift;
    my $tagdata = shift;

    log_print($Utils::NOTICE, $self -> {"verbose"}, "Use if deprecated [image] tag with attributes '$tagdata'"); 

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Image tag attribute list does not include name")
         && return "<p class=\"error\">Image tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # Construct the URL of the image, relative to the module directory
    my $url = "../../images/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    # The image style deals with width, height, and other stuff...
    my $imgstyle = "border: none;";
    $imgstyle .= " width: $attrs{'width'};"   if($attrs{"width"});
    $imgstyle .= " height: $attrs{'height'};" if($attrs{"height"});

    return load_complex_template($self -> {"templatebase"}."/theme/module/image.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***imgstyle***" => $imgstyle,
                                  "***alt***"      => $attrs{"alt"} || "",
                                  "***title***"    => $attrs{"title"} || ""});
}


## @method $ convert_anim($tagdata)
# Convert an anim tag to html markup. This processes the specified list of tag args
# and generates the html elements needed to include a flash movie, or an error 
# message to include in the document.
#
# @param tagdata  The anim tag attribute list
# @return The string to replace the animtag with - either a chunk of html,
#         or an error message.
sub convert_anim {
    my $self    = shift;
    my $tagdata = shift;

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Anim tag attribute list does not include name")
         && return "<p class=\"error\">Anim tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # As well as width and height
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Anim tag attribute list is missing width or height information")
         && return "<p class=\"error\">Anim tag attribute list is missing width or height information </p>")
        if(!$attrs{"width"} || !$attrs{"height"});
    
    # Construct the URL of the anim, relative to the module directory
    my $url = "../../anims/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    return load_complex_template($self -> {"templatebase"}."/theme/module/anim.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***width***"    => $attrs{"width"},
                                  "***height***"   => $attrs{"height"}});
}


## @method $ convert_applet($tagdata)
# Convert an applet tag to html markup. This processes the specified list of tag args
# and generates the html elements needed to include an applet, or an error 
# message to include in the document.
#
# @param tagdata  The applet tag attribute list
# @return The string to replace the applet tag with - either a chunk of html,
#         or an error message.
sub convert_applet {
    my $self    = shift;
    my $tagdata = shift;

    log_print($Utils::NOTICE, $self -> {"verbose"}, "Use if deprecated [applet] tag with attributes '$tagdata'"); 

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Applet tag attribute list does not include name")
         && return "<p class=\"error\">Applet tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # As well as width and height
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Applet tag attribute list is missing width or height information")
         && return "<p class=\"error\">Applet tag attribute list is missing width or height information </p>")
        if(!$attrs{"width"} || !$attrs{"height"});
    
    # Construct the URL of the anim, relative to the module directory
    my $url = "../../applets/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    return load_complex_template($self -> {"templatebase"}."/theme/module/applet.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***width***"    => $attrs{"width"},
                                  "***height***"   => $attrs{"height"},
                                  "***codebase***" => $attrs{"codebase"} || "",
                                  "***archive***"  => $attrs{"archive"} || "",
                                 });
}


## @method $ convert_local($text, $data, $stepid, $lcount, $level, $width, $height)
# Converts a local tag into the appropriate html. This will process the specified
# arguments and data into a popup on the page.
#
# @todo This code currently generates a separate file containing the popup text and
#       generates a html block that opens the file in a popup window. This is 
#       VASTLY less than useful, and should be changed to use div element popups.
#       SEE ALSO: http://www.pat-burt.com/web-development/how-to-do-a-css-popup-without-opening-a-new-window/
# @param text   The text to show in the popup link.
# @param data   The contents of the popup. Should be valid html.
# @param stepid The id of the step the popup occurs in.
# @param lcount The popup count id for this step.
# @param level  The step difficulty level. Must be green, yellow, orange, or red.
# @param width  Optional window width. Defaults to 640.
# @param height Optional window height. Defaults to 480.
# @return The string to replace the local tag with, or an error message.
sub convert_local {
    my ($self, $text, $data, $stepid, $lcount, $level, $width, $height) = @_;
  
    $width  = 640 if(!defined($width)  || !$width);
    $height = 480 if(!defined($height) || !$height);

    # convert escaped characters to real ones
    # $data = text_to_html(fix_entities($data));
    $data =~ s/\\\[/\[/g;
    $data =~ s/\\\"/\"/g;
    #$data =~ s/&lt;/</g;
    #$data =~ s/&gt;/>/g;

    open(LOCAL, "> local-$stepid-$lcount.html")
        or die "FATAL: Unable to open local-$stepid-$lcount.html: $!";

    print LOCAL load_complex_template($self -> {"templatebase"}."/theme/module/local.tem",
                                      {"***title***"   => $text,
                                       "***body***"    => $data,
                                       "***include***" => $self -> {"globalheader"},
                                       "***version***" => $self -> {"cbtversion"},
                                       "***level***"   => $level});
    close(LOCAL);

    return load_complex_template($self -> {"templatebase"}."/theme/module/local_link.tem",
                                 {"***text***"   => $text,
                                  "***stepid***" => $stepid,
                                  "***lcount***" => $lcount,
                                  "***width***"  => $width,
                                  "***height***" => $height,
                                 });
}


## @method $ convert_interlink($anchor, $text)
# Convert a link to a target into a html hyperlink. This will attempt to locate 
# the anchor specified and create a link to it.
#
# @param anchor The name of the anchor to be linked to.
# @param text   The text to use as the link text.
# @return A HTML link to the specified anchor, or an error message if the anchor 
#         can not be found.
sub convert_interlink {
    my $self   = shift;
    my $anchor = shift;
    my $text   = shift;
    my $stepid = shift;
    my $module = shift;

    my $targ = $self -> {"anchors"} -> {$anchor};
    if(!$targ) {
        log_print($Utils::NOTICE, $self -> {"verbose"}, "Unable to locate anchor $anchor. Link text is '$text' in $module step $stepid");
        return '<span class="error">'.$text.' (Unable to locate anchor '.$anchor.')</span>';
    }
    
    my $step = @$targ[2];
    # prepent 0 if the step number is less than 10, and it doesn't already start with a leading 0
    $step = "0$step" if($step < 10 && $step !~ /^0/);   

    return "<a href=\"../../@$targ[0]/@$targ[1]/step".$step.".html#$anchor\">$text</a>";
}


## @method $ convert_step_tags($content, $stepid, $level)
# Convert any processor markup tags in the supplied step text into the equivalent 
# html. This function scans the provided text for any of the special marker tags
# supported by the processor and replaces them with the appropriate html, using
# the various convert_ functions as needed to support the process.
#
# @param content The step text to process.
# @param stepid  The step's id number.
# @param level   The difficulty level of the step, should be green, yellow, 
#                orange, or red.
# @return The processed step text.
sub convert_step_tags {
    my $self    = shift;
    my $content = shift;
    my $stepid  = shift;
    my $level   = shift;
    my $module  = shift;
    my $lcount  = 0;

    # Glossary conversion
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\/\s*\]}{$self->convert_terms($1)}ige;              # [glossary term="" /]
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\].*?\[/glossary\]}{$self->convert_terms($1)}igse;  # [glossary term=""]...[/glossary]

    # Image conversion
    $content =~ s{\[img\s+(.*?)\/?\s*\]}{$self -> convert_image($1)}ige;  # [img name="" width="" height="" alt="" title="" align="left|right|center" /]

    # Anim conversion
    $content =~ s/\[anim\s+(.*?)\/?\s*\]/$self -> convert_anim($1)/ige;   # [anim name="" width="" height="" align="left|right|center" /]

    # Applet conversion
    $content =~ s/\[applet\s+(.*?)\/?\s*\]/$self -> convert_applet_newstyle($1)/ige; # [anim name="" width="" height="" codebase="" archive="" /]

    # clears
    $content =~ s/\[clear\s*\/?\s*\]/<div style="clear: both;"><\/div>/giso; # [clear /]

    # Local conversion
    $content =~ s/\[local\s+text\s*=\s*"(.*?)"\s+width\s*=\s*"(\d+)"\s+height\s*=\s*"(\d+)"\s*\](.*?)\[\/\s*local\s*\]/$self -> convert_local($1, $4, $stepid, ++$lcount, $level, $2, $3)/isge;
    $content =~ s/\[local\s+text\s*=\s*"(.*?)"\s*\](.*?)\[\/\s*local\s*\]/$self -> convert_local($1, $2, $stepid, ++$lcount, $level)/isge;

    # links
    $content =~ s{\[link\s+(?:to|name)\s*=\s*\"(.*?)\"\s*\](.*?)\[/\s*link\s*\]}{$self -> convert_interlink($1, $2, $stepid, $module)}isge; # [link to=""]link text[/link]

    # anchors
    $content =~ s/\[target\s+name\s*=\s*\"(.*?)\"\s*\/?\s*\]/<a name=\"$1\"><\/a>/gis; # [target name="" /]

    # convert references and do any work needed to compress them (eg: converting [1][2][3] to [1,2,3])
    if($self -> {"refhandler"}) {
        $content =~ s/\[ref\s+(.*?)\s*\/?\s*\]/$self -> {"refhandler"} -> convert_references($1)/ige;
        $content = $self -> {"refhandler"} -> compress_references($content);
    }

    return $content;
}


# ============================================================================
#  Interlink handling
#  

# Record the position of named anchor points, used when doing cross-step linking 
sub set_anchor_point {
    my ($self, $hashref, $name, $theme, $module, $step) = @_;

    log_print($Utils::NOTICE, $self -> {"verbose"}, "Setting anchor $name in $theme/$module/$step");

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;

    my $args = $hashref -> {$name};
    blargh("Redefinition of target $name in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]") if($args);

    # Record the location
    $hashref -> {$name} = [$theme, $module, $step];
}


# ============================================================================
#  Glossary handling
#  

# Generate a glossary and references block at a given level in the document. This will
# generate a block with the glossary and references links enabled or disabled depending
# on whether the global glossary and references hashes contain data.
sub build_glossary_references {
    my $self       = shift;
    my $level      = shift;

    # construct the filename for the subtemplates
    my $glossary   = ($self -> {"terms"} && scalar(keys(%{$self -> {"terms"}}))) ? "glossary_en" : "glossary_dis";
    my $references = ($self -> {"refs"}  && scalar(keys(%{$self -> {"refs"}}))) ? "references_en" : "references_dis";
    my $name = $glossary."_".$references.".tem";

    # Load the subtemplate
    my $contents = load_complex_template($self -> {"templatebase"}."$level/$name");

    # And construct the block
    return  load_complex_template($self -> {"templatebase"}."$level/glossary_references_block.tem",
                                  { "***entries***" => $contents });
}  


# Record the location of glossary definitions or references
sub set_glossary_point {
    my ($self, $hashref, $term, $definition, $theme, $module, $step, $title) = @_;

    log_print($Utils::NOTICE, $self -> {"verbose"}, "Setting glossary entry $term in $theme/$module/$step");

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;
     
    # convert the term to a lowercase, space-converted name 
    my $key = lc($term);
    $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # only need to do the redef check if definition is specified
    if($definition) {
        my $args = $hashref -> {$key} -> {"defsource"};
        blargh("Redefinition of term $term in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]") if($args);       

        $hashref -> {$key} -> {"term"}       = $term;
        $hashref -> {$key} -> {"definition"} = $definition;
        $hashref -> {$key} -> {"defsource"}  = [$theme, $module, $step, $title];
        push(@{$hashref -> {$key} -> {"refs"}}, [$theme, $module, $step, $title]);
    
    # If it's not a (re)definition, mark the position anyway as we will want backrefs from the glossary
    } else {
        push(@{$hashref -> {$key} -> {"refs"}}, [$theme, $module, $step, $title]);
    }
}


# Construct a single entry in the glossary index. Returns an entry
# based on the the acive and defined status of the specified letter.
sub build_glossary_indexentry {
    my $self   = shift;
    my $letter = shift;
    my $link   = shift;
    my $def    = shift;
    my $active = shift;

    if($active) {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-active.tem",
                                     { "***letter***" => uc($letter) });
    } elsif($def && (scalar(@$def) > 0)) {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-indexed.tem",
                                     { "***letter***" => uc($letter),
                                       "***link***" => $link});        
    } else {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-notindexed.tem",
                                     { "***letter***" => uc($letter) });            
    }

}


# Builds the line of letters, number and symbol shown at the top of 
# glossary bodies to allow the user to jump between pages.
sub build_glossary_links {
    my $self    = shift;
    my $letter  = shift;
    my $charmap = shift;

    # ensure we always have lowercase letters
    $letter = lc($letter);

    my $index = "";

    # symbols...
    $index .= $self -> build_glossary_indexentry("@", "symb.html", $charmap -> {"symb"}, $letter eq "symb"); 

    # ... then numbers...
    $index .= $self -> build_glossary_indexentry("0-9", "digit.html", $charmap -> {"digit"}, $letter eq "0"); 

    # ... then letters
    foreach my $char ("a".."z") { 
        $index .= $self -> build_glossary_indexentry($char, "$char.html", $charmap -> {$char}, $letter eq $char); 
    }

    return load_complex_template($self -> {"templatebase"}."/glossary/indexline.tem",
                                 { "***entries***" => $index });
}


# Write all the entries for a specified character class to the named
# file.
sub write_glossary_file {
    my $self     = shift;
    my $filename = shift;
    my $title    = shift;
    my $letter   = shift;
    my $charmap  = shift;
    my $terms    = $self -> {"terms"};

    # write the file header...
    open(OUTFILE, "> $filename")
        or die "FATAL: Unable to open $filename: $!";

    print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/header.tem", 
                                        {"***title***"         => $title,
                                         "***include***"       => $self -> {"globalheader"},
                                         "***glosrefblock***"  => $self -> build_glossary_references("/glossary"),
                                         "***index***"         => $self -> build_glossary_links($letter, $charmap),
                                         "***breadcrumb***"    => load_complex_template($self -> {"templatebase"}."/glossary/breadcrumb-content.tem",
                                                                                        {"***letter***" => $letter })
                                        });

    # print out the entries for this letter.
    foreach my $term (@{$charmap -> {$letter}}) {
        # convert backlinks
        my $linkrefs = $terms -> {$term} -> {"refs"};
        my $backlinks = "";
        if($linkrefs && scalar(@$linkrefs)) {
            for(my $i = 0; $i < scalar(@$linkrefs); ++$i) {
                my $backlink = $linkrefs -> [$i]; 

                $backlinks .= load_complex_template($self -> {"templatebase"}."/glossary/backlink-divider.tem") if($i > 0);
                $backlinks .= load_complex_template($self -> {"templatebase"}."/glossary/backlink.tem",
                                                    { "***link***" => '../'.$backlink->[0].'/'.$backlink->[1].'/step'.lead_zero($backlink->[2]).'.html',
                                                      "***text***" => ($i + 1) });
            }
        }

        my $key = lc($term);
        $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
        $key =~ s/\s/_/g;     # replace spaces with underscores.

        print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/entry.tem",
                                            { "***termname***"   => $key,
                                              "***term***"       => $terms -> {$term} -> {"term"},
                                              "***definition***" => $terms -> {$term} -> {"definition"},
                                              "***backlinks***"  => $backlinks
                                              });                
    }

    print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/footer.tem", 
                                        { "***version***"      => $self -> {"cbtversion"} });
    close(OUTFILE);

}


# Write out the glossary pages.
sub write_glossary_pages {
    my $self   = shift;
    my $srcdir = shift;
    my $terms  = $self -> {"terms"};

    # do nothing if there are no terms...
    if($terms) {
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing glossary pages");

        # Create the glossary dir if it doesn't currently exist
        mkdir("$srcdir/glossary") unless(-e "$srcdir/glossary");
        
        # get a list of all the terms
        my @termlist = sort(keys(%$terms));

        # calculate which characters are missing and which are available
        my $charmap = {};
        foreach my $term (@termlist) {
            my $letter = lc(substr($term, 0, 1));

            # letters go into individual entries...
            if($letter =~ /^[a-z]$/) {
                push(@{$charmap -> {$letter}}, $term);
                
                # numbers all go together...
            } elsif($letter =~ /^\d$/) {
                push(@{$charmap -> {"digit"}}, $term);
                
                # everything else goes in the symbol group
            } else {
                push(@{$charmap -> {"symb"}}, $term);
            }

        }

        # Process the letters first...
        foreach my $letter ("a".."z") {
            if($charmap -> {$letter} && scalar(@{$charmap -> {$letter}})) {
                log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing $srcdir/glossary/$letter.html");
                $self -> write_glossary_file("$srcdir/glossary/$letter.html",
                                             "Glossary of terms starting with '".uc($letter)."'",
                                             $letter, $charmap);
            }
        }

        # Now numbers...
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing $srcdir/glossary/digit.html");
        $self -> write_glossary_file("$srcdir/glossary/digit.html",
                                     "Glossary of terms starting with digits",
                                     "digit", $charmap);
        
        # ... and everything else
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing $srcdir/glossary/symb.html");
        $self -> write_glossary_file("$srcdir/glossary/symb.html",
                                     "Glossary of terms starting with other characters",
                                     "symb", $charmap);
           
        # Finally, write the index page
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing $srcdir/glossary/index.html");
        open(INDEX, "> $srcdir/glossary/index.html")
            or die "Unable to open glossary index $srcdir/glossary/index.html: $!";
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/header.tem",
                                          {"***title***"        => "Glossary Index",
                                           "***glosrefblock***" => $self -> build_glossary_references("/glossary"),
                                           "***include***"      => $self -> {"globalheader"},
                                           "***index***"        => $self -> build_glossary_links("mu", $charmap),
                                           "***breadcrumb***"   => load_complex_template($self -> {"templatebase"}."/glossary/breadcrumb-indexonly.tem")
                                          });
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/index-body.tem");
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/footer.tem");
        close(INDEX);

        log_print($Utils::DEBUG, $self -> {"verbose"}, "Finished writing glossary pages");
    } else {
        log_print($Utils::WARNING, $self -> {"verbose"}, "No glossary terms to write");
    }

}


# ============================================================================
#  Page interlink and index generation code.
#  

# Sort steps by numeric order rather than alphabetically (avoids the list
# ending up as 'step1', 'step10', 'step11', etc...) 
sub numeric_order {
    my ($an) = $a =~ /^[a-zA-Z]+0*(\d+)\.html?$/;
    my ($bn) = $b =~ /^[a-zA-Z]+0*(\d+)\.html?$/;

    die "FATAL: Unable to obtain number from \$a = $a" if(!defined($an));
    die "FATAL: Unable to obtain number from \$b = $b" if(!defined($bn));
    return (0 + $an) <=> (0 + $bn);
}


## @method $ build_dependencies($entries, $metadata)
# Construct a string containing the module dependencies seperated by
# the index_dependence delimiter.
#
# @param entries  A reference to an array of module names forming a dependency.
# @param metadata A reference to the theme metadata hash.
# @return A string containing the dependency list.
sub build_dependencies {
    my $self     = shift;
    my $entries  = shift;
    my $metadata = shift;
    my $depend   = "";
    
    $entries = [ $entries ] if(!ref($entries)); # make sure we're looking at an arrayref
    my $count = 0;
    foreach my $entry (@$entries) {
        $depend .= load_complex_template($self -> {"templatebase"}."/theme/index_dependency_delimit.tem") if($count > 0);
        $depend .= load_complex_template($self -> {"templatebase"}."/theme/index_dependency.tem",
                                         {"***url***" => "#$entry",
                                          "***title***" => $metadata -> {"module"} -> {$entry} -> {"title"}});
        ++$count;
    }         

    return $depend;
}


## @method void write_theme_indexmap($themedir, $theme, $metadata, $headerinclude)
# Write out the contents of the specified theme's 'themeindex.html' and 'index.html' files.
# This will generate the theme-level text index (containing the list of modules in the 
# theme, their prerequisites and leadstos, and the steps they contain), and the 'cloud map'
# index page. 
#
# @param themedir      The directory containing the theme data.
# @param theme         The theme name as specified in the metadata name element.
# @param metadata      The theme metadata.
# @param headerinclude Any additional data to include in the header, optional.
sub write_theme_indexmap {
    my $self     = shift;
    my $themedir = shift;
    my $theme    = shift;
    my $metadata = shift;
    my $headerinclude = shift;

    # Build the main index
    # grab a list of module names, sorted by module order if we have order info or alphabetically if we don't
    my @modnames = sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                              if(!$metadata -> {"module"} -> {$a} -> {"indexorder"} or !$metadata -> {"module"} -> {$b} -> {"indexorder"});
                          defined($metadata -> {"module"} -> {$a} -> {"indexorder"}) ?
                              $metadata -> {"module"} -> {$a} -> {"indexorder"} <=> $metadata -> {"module"} -> {$b} -> {"indexorder"} :
                              $a cmp $b; }
                        keys(%{$metadata -> {"module"}});

    # For each module, build a list of steps.
    my $body = "";
    foreach my $module (@modnames) {
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Module: $module = ".$metadata -> {"module"} -> {$module} -> {"title"});

        # skip dummy modules
        next if($module eq "dummy" || $metadata -> {"module"} -> {$module} -> {"skip"});

        my ($prereq, $leadsto, $steps) = ("", "", "");

        # build the prerequisites and leadsto links for the module
        # Prerequisites first...
        my $entries = $metadata -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
        if($entries) {
            $prereq = load_complex_template($self -> {"templatebase"}."/theme/index_entry_prereqs.tem",,
                                            {"***prereqs***" => $self -> build_dependencies($entries, $metadata)});
        }

        # ... then the leadstos...
        $entries = $metadata -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
        if($entries) {
            $leadsto = load_complex_template($self -> {"templatebase"}."/theme/index_entry_leadsto.tem",
                                             {"***leadsto***" => $self -> build_dependencies($entries, $metadata)});
        }
        
         # ... and then the steps.
         foreach my $step (sort numeric_order keys(%{$metadata -> {"module"} -> {$module} -> {"steps"}})) {
            $steps .= load_complex_template($self -> {"templatebase"}."/theme/index_step.tem",
                                            {"***url***"   => "$module/".get_step_name($step),
                                             "***title***" => $metadata -> {"module"} -> {$module} -> {"steps"} -> {$step}});
        }

        # finally, glue them all together.
        $body .= load_complex_template($self -> {"templatebase"}."/theme/index_entry.tem",
                                       {"***title***"      => $metadata -> {"module"} -> {$module} -> {"title"},
                                        "***name***"       => $module,
                                        "***level***"      => $metadata -> {"module"} -> {$module} -> {"level"},
                                        "***difficulty***" => ucfirst($metadata -> {"module"} -> {$module} -> {"level"}),
                                        "***prereqs***"    => $prereq,
                                        "***leadsto***"    => $leadsto,
                                        "***steps***"      => $steps});
    }
     
    # dump the index.
    open(INDEX, "> $themedir/themeindex.html")
        or die "FATAL: Unable to open $themedir/themeindex.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/theme/themeindex.tem",
                                      {"***data***"         => $body,
                                       "***title***"        => $metadata -> {"title"},
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***themedrop***"    => $self -> get_map_theme_dropdown($theme, $metadata),
                                       "***glosrefblock***" => $self -> build_glossary_references("/theme"),
                                   });
    close(INDEX);


    # Build the theme map page...
    my $mapbody;
    log_print($Utils::DEBUG, $self -> {"verbose"}, "Building theme map page for".($metadata -> {"title"} || "Unknown theme"));

    # First load any metadata-specified content, if any...
    if($metadata -> {"includes"} -> {"resource"}) {
        my $includes = $metadata -> {"includes"} -> {"resource"};
        $includes = [ $includes ] if(!ref($includes)); # make sure we're looking at an arrayref
        foreach my $include (sort(@$includes)) {
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Including $include");
            
            # if the include is not absolute, prepend the theme directory
            $include = "$themedir/$include" if($include !~ /^\//);

            my $content = load_complex_template($include);
            if($content) {
                $mapbody .= $content;
            } else {
                blargh("Unable to open include file $include: $!");
                $mapbody .= "<p class=\"error\">Unable to open include file $include: $!</p>\n";
            }
        }
    }
    $mapbody = '<p class="error">No body content specified for this theme. Add an <includes> section to the metadata!</p>' if(!$mapbody);

    open(INDEX, "> $themedir/index.html")
        or die "FATAL: Unable to open $themedir/index.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/theme/index.tem",
                                      {"***body***"         => $mapbody,
                                       "***title***"        => $metadata -> {"title"},
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***themedrop***"    => $self -> get_map_theme_dropdown($theme, $metadata),
                                       "***glosrefblock***" => $self -> build_glossary_references("/theme"),
                                      });
    close(INDEX);
}


## @method $ build_courseindex_deps($entries, $metadata, $theme)
# Create module dependency entries for the top-level course index. This will
# process the supplied entries into dependency list templates and return the
# composite string.
#
# @param entries  A reference to an array of module names forming a dependency.
# @param metadata A reference to the course-wide composite metadata hash.
# @param theme    The current theme name.
# @return A string containing the dependency list.
sub build_courseindex_deps {
    my $self     = shift;
    my $entries  = shift;
    my $metadata = shift;
    my $theme    = shift;
    my $depend   = "";
    
    $entries = [ $entries ] if(!ref($entries)); # make sure we're looking at an arrayref
    my $count = 0;
    foreach my $entry (@$entries) {
        $depend .= load_complex_template($self -> {"templatebase"}."/courseindex-dependency-delimit.tem") if($count > 0);
        $depend .= load_complex_template($self -> {"templatebase"}."/courseindex-dependency.tem",
                                         {"***url***" => "#$theme-$entry",
                                          "***title***" => $metadata -> {$theme} -> {"module"} -> {$entry} -> {"title"}});
        ++$count;
    }         

    return $depend;
}


## @method void write_courseindex($coursedir, $metadata, $headerinclude)
# Write out the course-wide courseindex file. This will generate a full index
# of the whole course, sorted by theme order and module order, and save the
# index to the top-level courseindex.html
#
# @param coursedir The directory into which the index should be written.
# @param metadata  A reference to the course-wide composite metadata hash.
# @param headerinclude Any additional data to include in the header, optional.
sub write_courseindex {
    my $self          = shift;
    my $coursedir     = shift;
    my $metadata      = shift;
    my $headerinclude = shift;
    my $body = "";

    # Obtain a sorted list of theme names
    my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                if(!defined($metadata -> {$a} -> {"indexorder"}) or !defined($metadata -> {$b} -> {"indexorder"}));
                            defined($metadata -> {$a} -> {"indexorder"}) ?
                                $metadata -> {$a} -> {"indexorder"} <=> $metadata -> {$b} -> {"indexorder"} :
                                $a cmp $b; 
                          }
                          keys(%$metadata);
    
    
    # Now we can process all the modules in the theme...
    foreach my $theme (@themenames) {

        # grab a list of module names, sorted by module order if we have order info or alphabetically if we don't
        my @modnames = sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                                  if(!$metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} or !$metadata -> {$theme} -> {"module"} -> {$b} -> {"indexorder"});
                              defined($metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"}) ?
                                  $metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} <=> $metadata -> {$theme} -> {"module"} -> {$b} -> {"indexorder"} :
                                  $a cmp $b; 
                            }
                            keys(%{$metadata -> {$theme} -> {"module"}});

        my $modbody = "";

        # For each module, build a list of steps and interlinks.
        foreach my $module (@modnames) {
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Module: $module = ".$metadata -> {$theme} -> {"module"} -> {$module} -> {"title"});

            # skip dummy modules
            next if($module eq "dummy" || $metadata -> {$theme} -> {"module"} -> {$module} -> {"skip"});

            my ($prereq, $leadsto, $steps) = ("", "", "");

            # build the prerequisites and leadsto links for the module
            # Prerequisites first...
            my $entries = $metadata -> {$theme} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
            if($entries) {
                $prereq = load_complex_template($self -> {"templatebase"}."/courseindex-module-prereqs.tem",,
                                                {"***prereqs***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }

            # ... then the leadstos...
            $entries = $metadata -> {$theme} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
            if($entries) {
                $leadsto = load_complex_template($self -> {"templatebase"}."/courseindex-module-leadsto.tem",
                                                 {"***leadsto***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }
        
            # ... and then the steps.
            foreach my $step (sort numeric_order keys(%{$metadata -> {$theme} -> {$module} -> {"steps"}})) {
                $steps .= load_complex_template($self -> {"templatebase"}."/courseindex-step.tem",
                                                {"***url***"   => "$theme/$module/".get_step_name($step),
                                                 "***title***" => $metadata -> {$theme} -> {$module} -> {"steps"} -> {$step}});
            }

            # finally, glue them all together.
            $modbody .= load_complex_template($self -> {"templatebase"}."/courseindex-module.tem",
                                              {"***title***"      => $metadata -> {$theme} -> {"module"} -> {$module} -> {"title"},
                                               "***name***"       => "$theme-$module",
                                               "***stepurl***"    => "$theme/$module/step01.html",
                                               "***level***"      => $metadata -> {$theme} -> {"module"} -> {$module} -> {"level"},
                                               "***difficulty***" => ucfirst($metadata -> {$theme} -> {"module"} -> {$module} -> {"level"}),
                                               "***prereqs***"    => $prereq,
                                               "***leadsto***"    => $leadsto,
                                               "***steps***"      => $steps});
        } # foreach my $module (@modnames) {
        
        # Shove the module into a theme...
        $body .= load_complex_template($self -> {"templatebase"}."/courseindex-theme.tem",
                                       {"***name***"    => $theme,
                                        "***title***"   => $metadata -> {$theme} -> {"title"},
                                        "***modules***" => $modbody});
    } # foreach $theme (@themenames) {

    # dump the index.
    open(INDEX, "> $coursedir/courseindex.html")
        or die "FATAL: Unable to open $coursedir/courseindex.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/courseindex.tem",
                                      {"***body***"         => $body,
                                       "***title***"        => "Course index",
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***glosrefblock***" => $self -> build_glossary_references("/"),
                                   });
    close(INDEX);
}


# Construct the next and previous fragments based on the current
# position within the module.
sub build_prev_next {
    my $self    = shift;
    my $steps   = shift;
    my $current = shift;
    my $level   = shift;
    my ($previous, $next, $prevlink, $nextlink);
    
    if($current > 0) {
        $previous = load_complex_template($self -> {"templatebase"}."/theme/module/previous_enabled.tem",
                                          {"***prevlink***" => get_step_name(@$steps[$current - 1]),
                                           "***level***"    => $level});
        $prevlink = load_complex_template($self -> {"templatebase"}."/theme/module/link_prevstep.tem",
                                          {"***prevstep***" => get_step_name(@$steps[$current - 1])});
    } else {
        $previous = load_complex_template($self -> {"templatebase"}."/theme/module/previous_disabled.tem",
                                          {"***level***"    => $level});
        $prevlink = "";
    }

    if($current < (scalar(@$steps) - 1)) {
        $next     = load_complex_template($self -> {"templatebase"}."/theme/module/next_enabled.tem",
                                          {"***nextlink***" => get_step_name(@$steps[$current + 1]),
                                           "***level***"    => $level});
        $nextlink = load_complex_template($self -> {"templatebase"}."/theme/module/link_nextstep.tem",
                                          {"***nextstep***" => get_step_name(@$steps[$current + 1])});
    } else {
        $next     = load_complex_template($self -> {"templatebase"}."/theme/module/next_disabled.tem",
                                          {"***level***"    => $level});
        $nextlink = "";
    }

    return ($previous, $next, $prevlink, $nextlink);
}


# returns true if the named module appears in the arrayref provided. Returns
# false otherwise. If the first argument is not an arrayref, it is coerced 
# into one. Used to determine whether the named module is a prerequisite or
# leadsto of another module.
sub is_related {
    my $entries = shift;
    my $check   = shift;

    return 0 if (!$entries); # do nothing if there are no entries

    $entries = [ $entries ] if(!ref($entries)); # makes sure this is an arrayref

    # return true if the name we are supposed to check appears in the list
    foreach my $entry (@$entries) {
        return 1 if($entry eq $check);
    }

    return 0;
}


# Builds the menus that will replace dropdown markers in the templates during
# processing. this should be called as part of the preprocessing work as the
# menus must have been built before any pages can be generated.
sub build_dropdowns {
    my $self   = shift;
    my $layout = shift;
    my $theme;

    my $themedrop_theme  = ""; # dropdown menu shown in theme index/maps
    my $themedrop_module = ""; # theme dropdown in modules 
    
    my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                if(!defined($layout -> {$a} -> {"indexorder"}) or !defined($layout -> {$b} -> {"indexorder"}));
                            defined($layout -> {$a} -> {"indexorder"}) ?
                                $layout -> {$a} -> {"indexorder"} <=> $layout -> {$b} -> {"indexorder"} :
                                $a cmp $b; 
                          }
                          keys(%$layout);

    # build the ordered list of themes for both levels.
    foreach $theme (@themenames) {
        $themedrop_theme   .= load_complex_template($self -> {"templatebase"}."/theme/themedrop-entry.tem",
                                                   { "***name***"  => $theme,
                                                     "***title***" => $layout -> {$theme} -> {"title"}});

        $themedrop_module .=  load_complex_template($self -> {"templatebase"}."/theme/module/themedrop-entry.tem",
                                                    { "***name***"  => $theme,
                                                      "***title***" => $layout -> {$theme} -> {"title"}});
    }

    # insert into the handler object for access later
    $self -> {"dropdowns"} -> {"themes_theme"}  = load_complex_template($self -> {"templatebase"}."/theme/themedrop.tem",
                                                                        { "***entries***" => $themedrop_theme });
    $self -> {"dropdowns"} -> {"themes_module"} = load_complex_template($self -> {"templatebase"}."/theme/module/themedrop.tem",
                                                                        { "***entries***" => $themedrop_module });
    
    # now build up the step level module and step menus
    foreach $theme (@themenames) {
        my @modulenames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                                      if(!$layout -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} or !$layout -> {$theme} -> {"module"} -> {$b} -> {"indexorder"});
                                  defined($layout -> {$theme} -> {"module"} -> {$a} -> {"indexorder"}) ?
                                      $layout -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} <=> $layout -> {$theme} -> {"module"} -> {$b} -> {"indexorder"} :
                                      $a cmp $b; }
                                keys(%{$layout -> {$theme} -> {"module"}});

        foreach my $module (@modulenames) {
            my $moduledrop = "";
            
            # first create the module dropdown for this module (ie: show all modules in this theme and how they relate)
            foreach my $buildmod (@modulenames) {
                my $relationship = "";
                
                # first determine whether buildmod is a prerequisite, leadsto or the current module
                if($buildmod eq $module) {
                    $relationship = "-current";
                } elsif(is_related($layout -> {$theme} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"}, $buildmod)) {
                    $relationship = "-prereq";
                } elsif(is_related($layout -> {$theme} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"}, $buildmod)) {
                    $relationship = "-leadsto";
                } 

                $moduledrop .= load_complex_template($self -> {"templatebase"}."/theme/module/moduledrop-entry".$relationship.".tem",
                                                     { "***level***" => $layout -> {$theme} -> {"module"} -> {$buildmod} -> {"level"},
                                                       "***title***" => $layout -> {$theme} -> {"module"} -> {$buildmod} -> {"title"},
                                                       "***name***"  => $buildmod });
            }

            # store the generated menu for this module
            $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"modules"} = load_complex_template($self -> {"templatebase"}."/theme/module/moduledrop.tem",
                                                                                                   {"***entries***" => $moduledrop });

            # Now build the list of steps for this module
            my $stepdrop = "";
            foreach my $step (sort numeric_order keys(%{$layout -> {$theme} -> {$module} -> {"steps"}})) {
                $stepdrop .= load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop-entry.tem",
                                                   { "***name***" => get_step_name($step),
                                                     "***title***" => $layout -> {$theme} -> {$module} -> {"steps"} -> {$step}});
            }
            die "FATAL: No step stored for \{$theme\} -> \{$module\} -> \{steps\} in:\n".Data::Dumper -> Dump([$layout], ['*layout']) if(!$stepdrop);

            # and store
            $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"steps"} = load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop.tem",
                                                                                                 {"***entries***" => $stepdrop });

        } # foreach my $module (@modulenames) {

    } # foreach my $theme (@themenames) {
}


# returns a string containing the theme dropdown menu with the current theme 
# marked. The menu produced is suitable for use in steps.
sub get_step_theme_dropdown {
    my $self     = shift;
    my $theme    = shift;
    my $metadata = shift;

    # Load the chunk that needs to be located in the dropdown
    my $anchor = load_complex_template($self -> {"templatebase"}."/theme/module/themedrop-entry.tem",
                                       { "***name***" => $theme,
                                         "***title***" => $metadata -> {"title"}});
                                       
    # And the chunk that should replace the bit above
    my $replace = load_complex_template($self -> {"templatebase"}."/theme/module/themedrop-entry-current.tem",
                                       { "***current***" => ' class="current"',
                                         "***name***"    => $theme,
                                         "***title***"   => $metadata -> {"title"}});
 
    die "FATAL: Unable to open anchor template themedrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template themedrop-entry.tem: $!" if(!$replace);

    # copy the theme dropdown so we can wrangle it
    my $dropdown = $self -> {"dropdowns"} -> {"themes_module"};

    # replace the current theme
    $dropdown =~ s/\Q$anchor\E/$replace/;

    # now nuke the remainder of the current tags
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# returns a string containing the theme dropdown menu with the current theme 
# marked. The menu produced is suitable for use in theme maps.
sub get_map_theme_dropdown {
    my $self     = shift;
    my $theme    = shift;
    my $metadata = shift;

    # Load the chunk that needs to be located in the dropdown
    my $anchor = load_complex_template($self -> {"templatebase"}."/theme/themedrop-entry.tem",
                                       { "***name***" => $theme,
                                         "***title***" => $metadata -> {"title"}});
                                       
    # And the chunk that should replace the bit above
    my $replace = load_complex_template($self -> {"templatebase"}."/theme/themedrop-entry-current.tem",
                                       { "***current***" => ' class="current"',
                                         "***name***"    => $theme,
                                         "***title***"   => $metadata -> {"title"}});

    die "FATAL: Unable to open anchor template themedrop_entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template themedrop_entry.tem: $!" if(!$replace);

    # copy the theme dropdown so we can wrangle it
    my $dropdown = $self -> {"dropdowns"} -> {"themes_theme"};

    # replace the current theme
    $dropdown =~ s/\Q$anchor\E/$replace/;

    # now nuke the remainder of the current tags
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# Obtain a string for the step dropdown, marking the current step so it can be 
# inserted into the step body.
sub get_step_dropdown {
    my $self   = shift;
    my $theme  = shift;
    my $module = shift;
    my $step   = shift;
    my $title  = shift;

    # set up a chunk to use as an anchor in the menu
    my $anchor = load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop-entry.tem",
                                       { "***name***" => get_step_name($step),
                                         "***title***" => $title });

    # this chunk will replace the above
    my $replace = load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop-entry.tem",
                                        { "***current***" => ' class="current"',
                                          "***name***"    => get_step_name($step),
                                          "***title***"   => $title });
    
    die "FATAL: Unable to open anchor template stepdrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template stepdrop-entry.tem: $!" if(!$replace);

    # Create a copy of the step dropdown so it can be modified
    my $dropdown = $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"steps"};

    # replace the current step
    $dropdown =~ s/\Q$anchor\E/$replace/;
    
    # and nuke the remainder of the current markers
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# ============================================================================
#  Cleanup code.
#  

sub cleanup_module {
    my $self = shift;
    my $moddir = shift;
    my $modname = shift;

    `rm -f $moddir/node*.html` unless($self -> {"debug"});
}


sub cleanup_lists {
    my $self   = shift;
    my $srcdir = shift;
    
    `rm -f $srcdir/animlist.txt`;
    `rm -f $srcdir/imagelist.txt`;
    `rm -f $srcdir/appletlist.txt`;    
    `rm -f $srcdir/version.txt`;    
}


# ============================================================================
#  Postprocess
#

## @method void framework_template($source, $dest, $template)
# Attempt to template a top-level framework file. This will attempt to load and
# parse the contents of the specified framework file, and if it can extract the
# required data (title and 'real' body) it will save the data to dest using the
# specified template. If the required data can not be parsed from the file, this
# simply copies source to dest.
#
# @param source   The file to be processed.
# @param dest     The name of the file to write the processed data to.
# @param template The template to use when generating the output file, if possible.
sub framework_template {
    my ($self, $source, $dest, $template) = @_;

    # First load the source file and extract the gubbins we're interested in
    open(SOURCE, $source)
        or die "FATAL: Unable to open top-level source file $source: $!";

    undef $/;
    my $sourcedata = <SOURCE>;
    $/ = "\n";

    close(SOURCE);

    my ($title, $content) = $sourcedata =~ m{<title>(.*?)</title>.*<div\s+id="content">(.*?)</div>\s*<!-- id="content" -->}iso;

    if($title && $content) {  
        open(DEST, "> $dest")
            or die "FATAL: Unable to save top-level file $dest: $!";
        
        print DEST load_complex_template($self -> {"templatebase"}."/$template",
                                         {"***title***"         => $title,
                                          "***body***"          => $content,
                                          "***version***"       => $self -> {"cbtversion"},
                                          "***glosrefblock***"  => $self -> build_glossary_references("/"),
                                      });

        close(DEST);
    } else {
        blargh("HTMLOutputhandler::framework_template(): Unable to locate required sections in $source, falling back on copy");
        `cp $source $dest`;
    }

}


## @method void framework_merge($outdir, $framedir)
# Merge the framework directory into the output, rewriting the content into the
# templates as needed.
#
# @param outdir   The directory to write the templated framework files to.
# @param franedir The framework directory to read data from.
sub framework_merge {
    my ($self, $outdir, $framedir) = @_;

    opendir(FRAME, $framedir)
        or die "FATAL: Unable to open framework directory: $!";

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Merging framework at $framedir to $outdir...");

    while(my $entry = readdir(FRAME)) {
        next if($entry =~ /^\./);

        # if the entry is a directory then we want to simply copy it (NOTE: This behaviour depends
        # on the framework html files being in the top level of the tree. Were this is not the case
        # then far more advanced path handling would be required in generating the templated pages.
        # Unless there is a /blindingly/ good reason, I suggest avoiding changing this setup!)
        if(-d "$framedir/$entry") {
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Copying directory $framedir/$entry and its contents to $outdir...");
            my $out = `cp -rv $framedir/$entry $outdir`;
            log_print($Utils::DEBUG, $self -> {"verbose"}, "cp output is:\n$out");
        
        # process html files
        } elsif($entry =~ /\.html?$/) {
            my ($name) = $entry =~ /^(.*?)\.html?$/;
            die "FATAL: HTMLOutputhandler::framework_merge(): unable to get name from $entry!" if(!$name);
            
            # First, if a template exists with the same name as the file, use it
            if(-e $self -> {"templatebase"}."/$name.tem") {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "$name.tem");

            # Handle popups...
            } elsif($entry =~ /_popup.html?$/) {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "popup.tem");

            # Otherwise pass through the standard template
            } else {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "global.tem");
            }
        # otherwise just straight-copy the file, as we don't know what to do with it
        } else {
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Copying $framedir/$entry to $outdir...");
            my $out = `cp -rv $framedir/$entry $outdir`;
            log_print($Utils::DEBUG, $self -> {"verbose"}, "cp output is: $out");
        }   
    }

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Merge complete.");

    closedir(FRAME);

}


# ============================================================================
#  Core processing code.
#  

# Scan the document tree recording the location of anchors and glossary terms 
# in the course content
sub preprocess {
    my $self    = shift;
    my $srcdir  = shift;

    # A bunch of references to hashes built up as preprocessing proceeds.
    my $anchors = { };
    my $terms   = { };
    my $refs    = { };
    my $layout  = { }; 

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Starting preprocesss");

    # if we already have a terms hash, use it instead.
    $terms = $self -> {"terms"} if($self -> {"terms"});

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @themes = grep(!/^(\.|CVS)/, readdir(SRCDIR));
    
    foreach my $theme (@themes) {
        my $fulltheme = "$srcdir/$theme"; # prepend the source directory

        # if this is a directory, check inside for subdirs ($entry is a theme, subdirs are modules)
        if(-d $fulltheme) {
            opendir(MODDIR, $fulltheme)
                or die "FATAL: Unable to open theme directory $fulltheme for reading: $!";

            # load the metadata
            my $metadata = $self -> load_metadata($fulltheme);

            # skip directories without metadata
            next if($metadata == 1);

            $layout -> {$theme} = $metadata; #otherwise, store it.

            my @modules = grep(!/^(\.|CVS)/, readdir(MODDIR));

            foreach my $module (@modules) {
                my $fullmodule = "$fulltheme/$module"; # prepend the module directory...

                # skip CVS or svn directories
                next if($module eq "CVS" || $module eq ".svn");

                # If this is a module directory, we want to scan it for steps
                if(-d $fullmodule) {
                    opendir(SUBDIR, $fullmodule)
                        or die "FATAL: Unable to open module directory for reading: $!";
            
                    # Know grab a list of files we know how to process, then call the internal process
                    # function for each one, remembering to include the full path.
                    my @steps = grep(/^node\d+\.html/, readdir(SUBDIR));
            
                    if(scalar(@steps)) {
                        my $cwd = getcwd();
                        chdir($fullmodule);
                        
                        foreach my $step (@steps) {
                            log_print($Utils::DEBUG, $self -> {"verbose"}, "Preprocessing $fullmodule/$step... ");

                            # load the entire file so we can parse it for anchors
                            open(STEP, $step)
                                or die "FATAL: Unable to open $fullmodule/$step: $!";

                            undef $/;
                            my $content = <STEP>;
                            my ($title) = $content =~ m{<title>\s*(.*?)\s*</title>}im;
                            $/= "\n";
                            close(STEP);

                            pos($content) = 0; # just to be safe
                            while($content =~ /\[target\s+name\s*=\s*\"([-\w]+)\"\s*\/?\s*\]/isg) {
                                $self -> set_anchor_point($anchors, $1, $theme, $module, $step);
                            }

                            # reset so we can scan for glossary terms
                            pos($content) = 0; 
                            # first look for definitions...
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\](.*?)\[\/glossary\]}isg) {
                                $self -> set_glossary_point($terms, $1, $2, $theme, $module, $step, $title);
                            }

                            pos($content) = 0; 
                            # Now look for references to the terms...
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\/\s*\]}isg) {
                                $self -> set_glossary_point($terms, $1, undef, $theme, $module, $step, $title);
                            }

                            pos($content) = 0; 
                            # Next look for references if the reference handler is valid.
                            if($self -> {"refhandler"}) {
                                while($content =~ m{\[ref\s+(.*?)\s*/?\s*\]}isg) {
                                    $self -> {"refhandler"} -> set_reference_point($refs, $1, $theme, $module, $step, $title);
                                }
                            }

                            # record the step details for later menu generation
                            log_print($Utils::DEBUG, $self -> {"verbose"}, "Recording $title step as $theme -> $module -> steps -> $step");                         
                            $layout -> {$theme} -> {$module} -> {"steps"} -> {$step} = $title;

                            log_print($Utils::DEBUG, $self -> {"verbose"}, "Done preprocessing $fullmodule/$step");
                                
                        }
                        chdir($cwd);
                    }

                    closedir(SUBDIR);
                }
            }
            closedir(MODDIR);
        }
    }
    print Data::Dumper -> Dump([$layout], ['*layout']) if($self -> {"verbose"} > 1);

    closedir(SRCDIR);
    
    $self -> {"anchors"} = $anchors;
    $self -> {"terms"}   = $terms;
    $self -> {"refs"}    = $refs;

    $self -> build_dropdowns($layout);
    my $dropdowns = $self -> {"dropdowns"};
    print Data::Dumper -> Dump([$dropdowns], ['*dropdowns']) if($self -> {"verbose"} > 1);
 
    # Store all the metadatas, we need them to construct the coursewide index
    $self -> {"fullmap"} = $layout;

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Finished preprocesss");
}


sub process_step {
    my $self      = shift;
    my $filename  = shift;
    my $indexdata = shift;
    my $previous  = shift;
    my $next      = shift;
    my $firststep = shift;
    my $prevlink  = shift;
    my $nextlink  = shift;
    my $laststep  = shift;
    my $theme     = shift;
    my $module    = shift;
    my $include   = shift;
    my $maxstep   = shift;
    my $metadata  = shift;
    
    # grab the step ID from the filename
    my ($stepid) = $filename =~ /^\D+(\d+(.\d+)?).html?$/;

    # load the entire file so we can parse it
    open(STEP, $filename)
        or die "FATAL: Unable to open $filename: $!";
    
    undef $/;
    my $content = <STEP>;
    $/= "\n";
    close(STEP);
    
    # extract the bits we're interested in...
    my ($title, $body);
    ($title) = $content =~ /<title>\s*(.*?)\s*<\/title>/si;
    ($body ) = $content =~ /<body.*?>\s*(.*?)\s*(<hr>)?\s*<\/body>/si;

    die "FATAL: Unable to read body from $filename" if(!$body);

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Obtained body for step $filename, title is $title. Processing body.");

    # Strip inline title
    $body =~ s/<h\d><a name=".*?">.*?<\/a>\s*<\/h\d>//si;
    
    # convert local node links to step links
    $body =~ s/node(\d+).html/"step".$1.".html"/ge;

    # convert latex references to local images
    $body =~ s{file:/usr/lib/latex2html/icons/crossref.png}{../../images/crossref.png}gi;

    # back-convert escaped links
    $body =~ s/&lt;a\s+href="(.*?)"\s*&gt;/<a href="$1">/gi;
    $body =~ s/&lt;\/a&gt;/<\/a>/gi;

    # Store the title for step
    $indexdata -> {get_step_name($filename)} = $title;

    # tag conversion
    $body = $self -> convert_step_tags($body, $stepid, $metadata -> {"module"} -> {$module} -> {"level"}, $module);

    # build an uppercase version of the level name for presentation
    my $difficulty = ucfirst($metadata -> {"module"} -> {$module} -> {"level"});

    # Save the step back...
    log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing out processed data to ".get_step_name($filename));
    open(STEP, "> ".get_step_name($filename))
        or die "FATAL: Unable to open $filename: $!";
       
    print STEP load_complex_template($self -> {"templatebase"}."/theme/module/step.tem",
                                     {"***title***"         => $title,
                                      "***body***"          => $body,
                                      "***previous***"      => $previous,
                                      "***next***"          => $next,
                                      "***startlink***"     => load_complex_template($self -> {"templatebase"}."/theme/module/link_firststep.tem", { "***firststep***" => $firststep }),
                                      "***lastlink***"      => load_complex_template($self -> {"templatebase"}."/theme/module/link_laststep.tem",  { "***laststep***"  => $laststep  }),
                                      "***prevlink***"      => $prevlink,
                                      "***nextlink***"      => $nextlink,
                                      "***level***"         => $metadata -> {"module"} -> {$module} -> {"level"},
                                      "***difficulty***"    => $difficulty,
                                      "***themename***"     => $metadata -> {"title"},
                                      "***themeurl***"      => $metadata -> {"../index.html"},
                                      "***modulename***"    => $metadata -> {"module"} -> {$module} -> {"title"},
                                      "***version***"       => $self -> {"cbtversion"},
                                      "***include***"       => $include,
                                      "***stepnumber***"    => $stepid,
                                      "***stepmax***"       => $maxstep,
                                      "***glosrefblock***"  => $self -> build_glossary_references("/theme/module"),
                                      "***themedrop***"     => $self -> get_step_theme_dropdown($theme, $metadata),
                                      "***moduledrop***"    => $self -> {"dropdowns"} -> {$theme} ->  {$module} -> {"modules"} || "<!-- No module dropdown! -->",
                                      "***stepdrop***"      => $self -> get_step_dropdown($theme, $module, $filename, $metadata) || "<!-- No step dropdown! -->" ,
                                      })
        or die "FATAL: Unable to write to ".get_step_name($filename).", possible cause: $@";

    close(STEP);

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing complete");

    # Try to do tidying if the tidy mode has been specified and it exists
    if($self -> {"tidy"}) {
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Tidying ".get_step_name($filename));
        if(-e $tidybin) {
            my $name = get_step_name($filename);

            # make a backup if we're running in debug mode
            `cp -f $name $name.orig` if($self -> {"debug"});

            # Now invoke tidy
            my $cmd = "$tidybin $tidyopts -m $name";
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Invoing $cmd");
            my $out = `$cmd 2>&1`;
            print $out if($self -> {"verbose"} > 1);            
        } else {
            blargh("Unable to run htmltidy: $tidybin does not exist");
        }
    }
    log_print($Utils::DEBUG, $self -> {"verbose"}, "Step processing complete");
}


sub process {
    my $self   = shift;
    my $srcdir = shift;
    my $frame  = shift;
    $self -> {"refhandler"} = shift;

    # kill the reference handler value if the caller has indicated one is not valid.
    if($self -> {"refhandler"} eq "none") {
        $self -> {"refhandler"} = undef;
        log_print($Utils::DEBUG, $self -> {"verbose"}, "HTMLOutputHandler disabling references processing");
    }

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Processing using HTMLOutputHandler");

    # preprocess to get the anchors and terms recorded
    $self -> preprocess($srcdir);
    $self -> preload_version($srcdir);
    $self -> write_glossary_pages($srcdir);

    if($self -> {"refhandler"}) {
        $self -> {"refhandler"} -> write_reference_page($srcdir);
    }

    # load the header include file
    my $include = $self -> preload_header_include($srcdir) || "";
    $self -> {"globalheader"} = $include;

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Preprocessing complete");

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @themes = grep(!/^(\.|CVS)/, readdir(SRCDIR));

    die "FATAL: Unable to locate any themes to parse in $srcdir" if(scalar(@themes) == 0);

    foreach my $theme (@themes) {
        my $fulltheme = "$srcdir/$theme"; # prepend the source directory
        log_print($Utils::DEBUG, $self -> {"verbose"}, "Processing $theme");

        # if this is a directory, check inside for subdirs ($theme is a theme, subdirs are modules)
        if(-d $fulltheme) {

            # Load the theme metadata
            my $metadata  = $self -> load_metadata($fulltheme);

            if($metadata && ($metadata != 1)) {
                # Get the list of module directories in this theme
                opendir(MODDIR, $fulltheme)
                    or die "FATAL: Unable to open module directory $fulltheme for reading: $!";
                my @modules = grep(!/^(\.|CVS)/, readdir(MODDIR));

                # Process each module.
                foreach my $module (@modules) { 
                    log_print($Utils::DEBUG, $self -> {"verbose"}, "Processing $module ($fulltheme/$module)");

                    my $fullmodule = "$fulltheme/$module"; # prepend the module directory...

                    # If this is a module directory, we want to scan it for steps
                    if(-d $fullmodule) {
                        
                        # Scan for steps
                        opendir(SUBDIR, $fullmodule)
                            or die "FATAL: Unable to open subdir for reading: $!";

                        # now grab a list of files we know how to process, then call the internal process
                        # function for each one, remembering to include the full path.
                        my @stepfiles = grep(/^node\d+\.html/, readdir(SUBDIR));
                        
                        if(scalar(@stepfiles)) {
                            my $cwd = getcwd();
                            chdir($fullmodule);

                            my $maxstep = get_maximum_stepid(\@stepfiles);
                            
                            $metadata -> {"module"} -> {$module} -> {"steps"} = { };
                            for(my $i = 0; $i < scalar(@stepfiles); ++$i) {
                                log_print($Utils::DEBUG, $self -> {"verbose"}, "Processing ".$stepfiles[$i]." as ".get_step_name($stepfiles[$i])."... ");
                                my ($previous, $next, $prevlink, $nextlink) = $self -> build_prev_next(\@stepfiles, $i, $metadata -> {"module"} -> {$module} -> {"level"});
                                $self -> process_step($stepfiles[$i], 
                                                      $metadata -> {"module"} -> {$module} -> {"steps"}, 
                                                      $previous, 
                                                      $next,
                                                      get_step_name($stepfiles[0]),
                                                      $prevlink,
                                                      $nextlink,
                                                      get_step_name($stepfiles[scalar(@stepfiles) - 1]),
                                                      $theme,
                                                      $module,
                                                      $include,
                                                      $maxstep,
                                                      $metadata);
                                log_print($Utils::DEBUG, $self -> {"verbose"}, "Finished processing $module ($fulltheme/$module)");
                            }
                            chdir($cwd);

                            $self -> cleanup_module($fullmodule, $module);
                        }

                        closedir(SUBDIR);
                    }
                }
                closedir(MODDIR);
                log_print($Utils::DEBUG, $self -> {"verbose"}, "Writing index files");
                $self -> write_theme_indexmap($fulltheme, $theme, $metadata, $include);

            } else { # if($metadata && ($metadata != 1)) {
                log_print($Utils::NOTICE, $self -> {"verbose"}, "Skipping directory $fulltheme: no metadata in directory");
            }
        } # if(-d $fulltheme) {
    } # foreach my $theme (@themes) {

    log_print($Utils::NOTICE, $self -> {"verbose"}, "HTMLOutputhandler processing complete");

    $self -> cleanup_lists($srcdir);

    closedir(SRCDIR);

    $self -> write_courseindex($srcdir, $self -> {"fullmap"});
    $self -> framework_merge($srcdir, $frame);

    return 1;
}



1;
