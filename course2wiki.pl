#!/usr/bin/perl -W

## @file
# Script to convert an APEcs/PEVEit course generated using previous
# versions of the course processor into a form suitable for importing
# into a wiki.
#
# For full documentation please see http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Course2wiki.pl
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
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
use utf8;

use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}

use Cwd;
use Data::Dumper;
use File::HomeDir;
use File::Path;
use Getopt::Long;
use HTML::TreeBuilder;
use HTML::WikiConverter;
use MediaWiki::API;
use MIME::Base64;
use Pod::Usage;
use Term::ANSIColor;
use XML::Simple;

# Local modules
use lib ("$path/modules"); # Add the script path for module loading
use lib ("/var/www/webperl"); # and to webperl
use Logger;
use Metadata;
use ProcessorVersion;
use Utils qw(load_file path_join find_bin write_pid)
use MCPUtils qw(get_password makedir load_config);
use MediaWiki::Wrap;

# How long should the user have to abort the process?
use constant ABORT_TIME => 5;

# default settings
my $default_config = { course_page   => "Course",
                       data_page     => "coursedata",
                       themes_title  => "Themes",
                       modules_title => "Modules",
                       metadata      => "Metadata",
                       media_page    => "Media"
    };

# various globals set via the arguments
my ($coursedir, $username, $password, $namespace, $dryrun, $force, $apiurl, $uploadurl, $verbose, $configfile, $pidfile, $quiet, $allow_naive, $only_theme) = ('', '', '', '', 0, 0, '', '', 0, '', '', 0, 0, '');
my $man = 0;
my $help = 0;

# Global logger. Yes, I know, horrible, but it'd be being passed around /everywhere/ anyway
my $logger = new Logger();

# Likewise with the configuration object.
my $config;

# A global metadata hash to help with course map generation
my $course_xmltree = {};

# And the source metadata needed to handle images
my $course_mdata   = {};

# And course glossary data
my $course_glosshash = {};


## @fn void warn_die_handler($fatal, @messages)
# A simple handler for warn and die events that changes the normal behaviour of both
# so that they print to STDOUT rather than STDERR.
#
# @param fatal    Should the function call exit rather than carry on as normal?
# @param messages The array of messages passed to the die or warn.
sub warn_die_handler {
    my $fatal = shift;
    my @messages = @_;

    print STDOUT @messages;
    exit 1 if($fatal);
}

# Override default warn and die behaviour to ensure that errors and
# warnings do not end up out-of-order in printed logs.
$SIG{__WARN__} = sub { warn_die_handler(0, @_); };
$SIG{__DIE__}  = sub { warn_die_handler(1, @_); };


# -----------------------------------------------------------------------------
#  Utility functions
#

## @fn void doomsayer()
# Warn the user that they have started the script without the dry-run option
# and without the force option, and give them ABORT_TIME seconds to abort the
# process.
sub doomsayer {

    # Print out a friendly, happy warning message
    print colored("-= WARNING * WARNING * WARNING * WARNING * WARNING * WARNING =-", 'bold red'), "\n\n";
    print         "You have launched course2wiki.pl without the --dry-run option.\n";
    print colored("      THIS SCRIPT WILL MODIFY THE CONTENTS OF THE WIKI!", 'bold yellow'),"\n";
    print         "If you are not certain the import will work. Press Ctrl+C now\nto abort the script and run it with the --dry-run option!\n\nContinuing in: ";

    # Countdown time!
    for(my $sec = ABORT_TIME; $sec > 0; --$sec) {
        print colored("$sec.. ", 'bold red');
        select((select(STDOUT), $| = 1)[0]); # Flush stdout

        sleep(1);
    }

    print "\nStarting course to wiki conversion.\n";
}


## @fn $ extract_coursemap($wikih, $media)
# Retrieve the contents of the course map for the imported course.
#
# @param wikih A reference to the MediaWiki::API wiki handle.
# @param media A refrence to a hash to store media file links in.
sub extract_coursemap {
    my $wikih = shift;
    my $media = shift;
    my $mapfile = path_join($coursedir, "coursemap.html");

    $logger -> print($logger -> DEBUG, "Processing $mapfile.");

    my $root = eval { HTML::TreeBuilder -> new_from_file($mapfile) };
    die "FATAL: Unable to load and parse $mapfile: $@" if($@);
    $root = $root -> elementify();

    # And now the content div
    my $content = $root -> look_down("id", "content");
    if(!$content) {
        $logger -> print($logger -> WARNING, "Unable to locate content div in $mapfile. Unable to load step.");
        $root -> delete();
        return undef;
    }

    # get the contents
    my $realcontent = $content -> as_HTML();
    $realcontent =~ s|^<div id="content">(.*)</div>$|$1|s;

    # save any media used in the content
    my @imglist = $realcontent =~ /src="(.*?\.(?:gif|png|jpg|swf))"/g;
    my $medialist = [];
    foreach my $src (@imglist) {
        my $outname = fix_media_name($src);
        $logger -> print($logger -> DEBUG, "Found image: $src storing as $outname");

        # Do the upload if possible
        my $errs = wiki_upload_media($wikih, path_join($coursedir, $src), $outname, $dryrun);
        $logger -> print($logger -> WARNING, $errs) if($errs);

        # store the media link for inclusion in the media page later
        push(@$medialist, wiki_link("File:$outname"));
    }
    $media -> {"Course Map"} = $medialist if(scalar(@$medialist));

    # Explicitly delete the tree to prevent memory leaks
    $root -> delete();

    return $realcontent;
}


## @fn $ load_legacy_resource($dirname, $resname)
# Load the content of the specified resource file from the directory, and
# return it as a character data block inside a <map> element.
#
# @param dirname The directory the resource is inside.
# @param resname The name of the resource to load.
# @return The resource contents inside a <map> element. If resources loading
#         failed, this will return $resname wrapped in a <map> element.
sub load_legacy_resource {
    my $dirname = shift;
    my $resname = shift;
    my $content;

    # If the resource name doesn't contain htmly characters, try to load the resource
    # into memory, if the load fails fall back on the resource name as the content.
    $content = load_file(path_join($dirname, $resname))
        unless($resname =~ m|[<"=/]|);

    # Fall back on the resource name if we have nothing yet.
    $content = $resname if(!$content);

    return '<map><![CDATA['.$content.']]></map>';
}


## @fn @ load_legacy_metadata($dirname)
# Attempt to load the metadata in the specified directory. During loading, this
# will try to correct the metadata contents to meet the current standard.
#
# @param dirname The name of the directory to load the metadata.xml file from.
# @return An array of two values: a reference to the parsed metadata tree hash
#         and the metadata string the tree was parsed from. If the parsing
#         fails for any reason, both will contain undef.
sub load_legacy_metadata {
    my $fullpath = shift;
    my $dirname  = shift;

    # If this fails, the file is probably not readable...
    my $content = load_file(path_join($fullpath, "metadata.xml"));
    if(!$content) {
        $logger -> print($logger -> WARNING, "Unable to load metadata in $dirname: $!");
        return (undef, undef);
    }

    # Fix up old xml as much as possible. Start by renaming the root..
    $content =~ s/metadata/theme/g;

    # Old resource elements used to contain the name of a file to use for the
    # theme map. Try loading and squirting the data in
    $content =~ s|<resource>(.*?)</resource>|load_legacy_resource($fullpath, $1)|ge;

    # Now fix any old resource and include tags
    $content =~ s/resource/map/g;
    $content =~ s/includes/maps/g;

    # Do we need to insert an indexorder attribute into the theme element?
    my ($telem) = $content =~ /(<\s*theme.*?>)/;
    $content =~ s/theme/theme indexorder="1"/ if($telem !~ /indexorder="\d+"/);

    # By this point the metadata should be in a form that is parsable, so give it a go
    my $mdata = Metadata -> new(logger => $logger);
    my $tree  = $mdata -> parse_metadata($content, $fullpath, $dirname, 1);

    # if loading failed, return undefs
    return (undef, undef) if(!$tree);

    # Otherwise we need to return thr tree and the string..
    return ($tree, $content);
}


## @fn $ load_legacy_glossary($gfile, $glosshash)
# Attempt to load the contents of the specified glossary file, and store the
# glossary terms in the provided glossary hash.
#
# @param gfile     The name of the glossary file to load.
# @parma glosshash A reference to a hash to store glossary entries in.
# @return The number of glossary entries loaded.
sub load_legacy_glossary {
    my $gfile     = shift;
    my $glosshash = shift;
    my $count = 0;

    $logger -> print($logger -> DEBUG, "Loading glosary data from '$gfile'");

    my $root = eval { HTML::TreeBuilder -> new_from_file($gfile) };
    die "FATAL: Unable to load and parse glossary file '$gfile': $@" if($@);
    $root = $root -> elementify();

    # Locate the content div, should be present even in old material
    my $content = $root -> look_down("id", "content");

    if($content) {
        # Locate the definition list, should be the first one, and get its first child
        my $node = $content -> find('dl');
        if($node) {
            $node = $node -> content -> [0];

            # This should be a dt node in a normal glossary page.
            if($node) {
                do {
                    # Each glossary dt contains the glossary term, and then the glossary
                    # data immediately after it contains the glossary explanation (usually
                    # followed by another dd with the reverse links, and a spacer, but they
                    # can be ignored).
                    if($node -> tag() eq "dt") {
                        my $name = $node -> as_text();
                        $node = $node -> right();
                        if($node -> tag() eq "dd") {
                            my $data = $node -> as_HTML();
                            # Remove leading dd and potentially trailing close.
                            $data =~ s/^<dd>//;
                            $data =~ s|</dd>$||;

                            # Store the glossary term
                            $glosshash -> {$name} = {"definition" => $data};
                            ++$count;
                        }
                    }
                    # Walk the level of the dt/dds here, until we hit the end of the secion.
                    $node = $node -> right();
                } while($node);
            }  else {
                $logger -> print($logger -> WARNING, "Glossary page definition list is empty.");
            }
        }  else {
            $logger -> print($logger -> WARNING, "Unable to locate definition list in glossary page.");
        }
    } else {
        $logger -> print($logger -> WARNING, "Unable to locate content div in glossary page. Content is: ".$root -> as_HTML());
    }
    $root -> delete();

    return $count;
}


## @fn $ sort_step_func()
# Sort filenames based on the first number in the name, discarding all letters.
#
# @return The numeric comparison of the first numbers encountered in the
#         filenames in $a and $b
sub sort_step_func {
    # obtain the *FIRST NUMBER IN THE FILENAME*
    my ($anum) = $a =~ /^[a-zA-Z_-]*0?(\d+)/o;
    my ($bnum) = $b =~ /^[a-zA-Z_-]*0?(\d+)/o;

    return $anum <=> $bnum;
}


## @fn $ fix_media_name($name)
# Takes the specified filename, removes any path component, and ensures that the
# name starts with the current namespace as a prefix.
#
# @param name The name to check and fix up.
# @return The corrected name.
sub fix_media_name {
    my $name = shift;

    $logger -> print($logger -> DEBUG, "Converting media name: $name");

    # Remove any path...
    $name =~ s|^.*?/([^/]+)$|$1|;

    # Prefix the name with the namespace if it isn't already
    $name = $namespace."_".$name unless($name =~ /^${namespace}_/);

    return $name;
}


# -----------------------------------------------------------------------------
#  HTML fixing functions

## @fn $ fix_glossary($term)
# Attempt to insert a glossary tag for the specified term. If a definition is found
# for the term, and it hasn't been included in the material yet, this will include
# the glossary term.
#
# @param term The term to generate a glossary tag for.
# @return the glossary tag to insert.
sub fix_glossary {
    my $term = shift;

    # Is the term defined, and not yet been included?
    if($course_glosshash -> {$term} &&
       $course_glosshash -> {$term} -> {"definition"} &&
       !$course_glosshash -> {$term} -> {"included"}) {
        $course_glosshash -> {$term} -> {"included"} = 1;

        # No need to convert the content here - it will be done later in convert_content
        return "[glossary term=\"$term\"]".$course_glosshash -> {$term} -> {"definition"}."[/glossary]";
    }

    # Otherwise, return a basic tag
    return "[glossary term=\"$term\"]";
}


## @fn $ fix_local($popup, $title, $wikih, $themedir, $moddir, $media)
# Convert a version 2 'local' popup link to a new style 'twpopup' popup. Note
# that this converts the old popup into the *html version* of a new popup, not
# <popup> taged, to avoid problems with WikiConverter.
#
# @param popup    The popup javascript.
# @param title    The title to show for the popup anchor.
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param themedir The name of the current theme directory.
# @param moddir   The name of the current module directory.
# @param media    A refrence to an array to store media file links in.
# @return A string containing the popup.
sub fix_local {
    my $popup    = shift;
    my $title    = shift;
    my $wikih    = shift;
    my $themedir = shift;
    my $moddir   = shift;
    my $media    = shift;

    # Get the name of the popup
    my ($localfile) = $popup =~ /^javascript:OpenPopup\((?:'|&#39;)(.*?)(?:'|&#39;)/;

    if(!$localfile) {
        $logger -> print($logger -> WARNING, "Unable to parse local popup file from '$popup'.");
        return "";
    }

    # Load the local file as if it was a step. This should be safe, provided locals never recurse
    my ($pagetitle, $body) = load_step_file($wikih, $localfile, $themedir, $moddir, $media);
    if(!$body) {
        $logger -> print($logger -> WARNING, "Unable to load local popup file from '$localfile'.");
        return "";
    }
    $logger -> print($logger -> DEBUG, "Loaded popup body for $title = '$localfile'. Body is:\n$body\n");

    return "<span class=\"twpopup-fixed\">$title<span class=\"twpopup-inner\">".encode_base64($body)."</span></span>";
}


## @fn $ fix_link($linkargs, $text, $wikih, $themedir, $moddir, $media)
# Attempt to convert the specified link and text to [link] tag suitable for
# passing through to output handlers. This will only convert links that appear
# to be relative links to anchors in the course - any links to external
# resources are returned as-is.
#
# @param linkargs  The contents of the <a...> element to process.
# @param text      The text to show for the link.
# @param wikih     A reference to the MediaWiki::API wiki handle.
# @param themedir  The name of the current theme directory.
# @param moddir    The name of the current module directory.
# @param steptitle The title of the current step.
# @param media     A refrence to an array to store media file links in.
# @return A string containing the link - either the [link] tag, or a <a> tag.
sub fix_link {
    my $linkargs  = shift;
    my $text      = shift;
    my $wikih     = shift;
    my $themedir  = shift;
    my $moddir    = shift;
    my $steptitle = shift;
    my $media     = shift;

    # Try to pull out the link
    my ($link) = $linkargs =~ /href="(.*?)"/i;
    if(!$link) {
        $logger -> print($logger -> WARNING, "Unable to parse href from $linkargs - link will be removed");
        return $text;
    }

    $logger -> print($logger -> DEBUG, "Attempting to convert link '$link' to wiki format.");

    my $result = "";

    # Is the link actually a version 2 "local" popup?
    if($link =~ /javascript:OpenPopup/) {
        $logger -> print($logger -> DEBUG, "Detected version 2 'local' popup. Converting to <popup>");

        $result = fix_local($link, $text, $wikih, $media)

    # Is the link a glossar entry?
    } elsif($link =~ m|(?:../)+glossary/\w+\.html#(?:.*)$|) {
        $logger -> print($logger -> DEBUG, "Detected glossary link to term $text, converting.");

        $result = fix_glossary($text);

    # Try to fix up links to modules. Module in the same theme
    } elsif($link =~ m|^../([^/]+)/step0?1.html?$|) {
        $result =  '{link}'."$namespace:".$course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$1} -> {"title"}."|$text".'{/link}';

    # Try to fix up links to modules. Module in another theme
    } elsif($link =~ m|^../../([^/]+)/([^/]+)/step0?1.html?$|) {
        if(!$only_theme || $only_theme eq $1) {
            $result = '{link}'."$namespace:".$course_xmltree -> {$1} -> {"theme"} -> {"module"} -> {$2} -> {"title"}."|$text".'{/link}';
        } else {
            $result = "<a href=\"$link\">$text</a><!-- can't convert cross-theme link in only_theme mode -->";
        }

    # Identify steps, but pass them through
    } elsif($link =~ m|step\d+.html?$|) {
        $logger -> print($logger -> WARNING,
                         "'".$course_xmltree -> {$themedir} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$moddir} -> {"title"}."' -> '".
                         "$steptitle': Detected link to step '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$moddir} -> {"title"}."' -> '".
                         $link."' ('$text'), unable to fix.");
        $result = "<a href=\"$link\">$text</a>";

    } elsif($link =~ m|../([^/])/step\d+.html?$|) {
        $logger -> print($logger -> WARNING,
                         "'".$course_xmltree -> {$themedir} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$moddir} -> {"title"}."' -> '".
                         "$steptitle': Detected link to step '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$1} -> {"title"}."' -> '".
                         $link."' ('$text'), unable to fix.");
        $result = "<a href=\"$link\">$text</a>";

    } elsif($link =~ m|../../([^/])/([^/])/step\d+.html?$|) {
        $logger -> print($logger -> WARNING,
                         "'".$course_xmltree -> {$themedir} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$themedir} -> {"theme"} -> {"module"} -> {$moddir} -> {"title"}."' -> '".
                         "$steptitle': Detected link to step '".
                         $course_xmltree -> {$1} -> {"theme"} -> {"title"}."' -> '".
                         $course_xmltree -> {$1} -> {"theme"} -> {"module"} -> {$2} -> {"title"}."' -> '".
                         $link."' ('$text'), unable to fix.");
        $result = "<a href=\"$link\">$text</a>";

    # if the link looks absolute, or has no anchor return it as-is
    } elsif($link =~ m|://| || $link !~ /#/) {
        $logger -> print($logger -> WARNING, "Unable to convert link '$link' ('$text') - check and correct if needed.");
        $result = "<a href=\"$link\">$text</a>";

    # We have a relative anchored link, so convert to a [link] tag
    } else {
        my ($anchor) = $link =~ /#(.*)$/;
        $result = "[link to=\"$anchor\"]".$text."[/link]";
    }

    $logger -> print($logger -> DEBUG, "Link '$link' converted to '$result'.");
    return $result;
}


## @fn $ fix_flash($wikih, $object, $media)
# Pull the width, height, and flash file name out of a (probable) flash
# object/embed tag combination, and convert to an intermediate string that
# will get it through HTML::WikiConverter unscathed.
#
# @param wikih  A reference to the MediaWiki::API wiki handle.
# @param object The text of the object/embed tags to process.
# @param media  A refrence to an array to store media file links in.
# @return A string containing the intermediate flash tag, or the original
#         object/embed combo.
sub fix_flash {
    my $wikih  = shift;
    my $object = shift;
    my $media  = shift;

    # Attempt to get the width, height, and flash file names
    my ($width)  = $object =~ /width="(\d+)"/;
    my ($height) = $object =~ /height="(\d+)"/;
    my ($flash)  = $object =~ /src="(.*?\.swf)"/;

    # If we have all three, it's probably a flash tag...
    if($width && $height && $flash) {
        my $outname = fix_media_name($flash);
        $logger -> print($logger -> DEBUG, "Found flash animation: $flash storing as $outname");

        # upload the file if possible
        my $errs = wiki_upload_media($wikih, $flash, $outname, $dryrun);
        $logger -> print($logger -> WARNING, $errs) if($errs);

        # store the media link for inclusion in the media page later, even if upload failed
        push(@$media, wiki_link("File:$outname"));

        return '{flash width="'.$width.'" height="'.$height.'"}'.$outname.'{/flash}';
    }

    $logger -> print($logger -> DEBUG, "Unable to convert potential flash object ($object)");

    # otherwise return it as-is, we can't fix it.
    return "<div>$object</div>";
}


## @fn $ fix_twpopup($wikih, $title, $encdata, $media, $fixed)
# Convert a TWPopup span sequence into a <popup> tag.
#
# @param wikih   A reference to the MediaWiki::API wiki handle.
# @param title   The title string for the popup.
# @param encdata The Base64 encoded popup body.
# @param media   A refrence to an array to store media file links in.
# @param fixed   If true, the content has already been converted.
# @return A string containing the <popup> tag.
sub fix_twpopup {
    my $wikih   = shift;
    my $title   = shift;
    my $encdata = shift;
    my $media   = shift;
    my $fixed   = shift;

    # Converting to mediawiki format will have killed the newlines in thebase64 encoded data, fix that
    $encdata =~ s/ /\n/g;

    # decode so that we can convert the content
    my $content = decode_base64($encdata);
    if($content) {
        $content = convert_content($wikih, $content, $media) if(!$fixed);
    } else {
        $content = $encdata;
    }

    return "<popup title=\"$title\">$content</popup>";
}


## @fn $ fix_image($wikih, $imgattrs, $media)
# Take the contents of an img tag and produce a mediawiki tag to
# take its place.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param imgattrs The image tag attribute list.
# @param media    A refrence to an array to store media file links in.
# @return An mediawiki image tag, or the original <img> if the imgattrs
#         can't be understood.
sub fix_image {
    my $wikih    = shift;
    my $imgattrs = shift;
    my $media    = shift;

    my ($imgname) = $imgattrs =~ /src="(.*?)"/;
    if(!$imgname) {
        $logger -> print($logger -> WARNING, "Malformed image <img $imgattrs/> - no source found!");
        return "<img $imgattrs/>";
    }

    # Does the image appear to be latex maths?
    if($imgattrs =~ /class="tex"/ && $imgattrs =~/alt="/) {
        # Yes, this looks like maths, try returning the contents of the alt in a maths tag
        my ($maths) = $imgattrs =~ /alt="(.*?)"/s;

        # Can't use <math> here, as HTML::WikiConverter will break it, so send back
        # something that can be easily converted.
        return "\{math\}$maths\{/math\}" if($maths);
    }

    # Image is not maths, or has no alt tag if it is, so upload image...
    my $outname = fix_media_name($imgname);
    $logger -> print($logger -> DEBUG, "Found maths image: $imgname storing as $outname");

    my $errs = wiki_upload_media($wikih, $imgname, $outname, $dryrun);
    $logger -> print($logger -> WARNING, $errs) if($errs);

    # store the media link for inclusion in the media page later
    push(@$media, wiki_link("File:$outname"));

    # Can't return a 'standard' image tag, as HTML::WikiConverter will <nowiki> wrap it,
    # so send back something we can identify and munge.
    return "\{Image:$outname\}";
}


## @fn $ convert_content($wikih, $content, $titletext, $themedir, $moddir, $media)
# Convert the provided content from HTML to MediaWiki markup.
#
# @todo Need to add support for applet import here.
#
# @param wikih     A reference to the MediaWiki::API wiki handle.
# @param content   The html content to convert to MediaWiki markup.
# @param titletext The title of the step.
# @param themedir  The name of the current theme directory.
# @param moddir    The name of the current module directory.
# @param media     A refrence to an array to store media file links in.
# @return The converted content.
sub convert_content {
    my $wikih     = shift;
    my $content   = shift;
    my $titletext = shift;
    my $themedir  = shift;
    my $moddir    = shift;
    my $media     = shift;

    # Convert links with anchors to [target] and [link] as needed...
    $content =~ s|<a\s+name="(.*?)">\s*</a>|[target name="$1"]|g;
    $content =~ s|<a\s*(.*?)\s*>(.*?)</a>|fix_link($1, $2, $wikih, $themedir, $moddir, $titletext, $media)|ges;

    # Fix flash, stage 1
    $content =~ s|<div>(<object.*?</object>)</div>|fix_flash($wikih, $1, $media)|ges;
    $content =~ s|<center>\s*(<object.*?</object>)\s*</center>|fix_flash($wikih, $1, $media)|geis;
    $content =~ s|(<object.*?</object>)|fix_flash($wikih, $1, $media)|geis;

    # Fix images, stage 1
    $content =~ s|<div.*?><img\s+(.*?)></div>|fix_image($wikih, $1, $media)|gies;
    $content =~ s|<a.*?><img\s+(.*?)></a>|fix_image($wikih, $1, $media)|gies;
    $content =~ s|<img\s+(.*?)>|fix_image($wikih, $1, $media)|gies;

    # Do html conversion
    my $mw = new HTML::WikiConverter(dialect => 'MediaWiki', preserve_templates => 1 );
    my $mwcontent = $mw -> html2wiki($content);

    # Fix links, stage 2
    $mwcontent =~ s|{link}(.*?){/link}|[[$1]]|g;

    # Fix flash, stage 2
    $mwcontent =~ s|{(/?flash.*?)}|<$1>|g;

    # Fix images, stage 2
    $mwcontent =~ s|{(/?math)}|<$1>|g;
    $mwcontent =~ s|{(Image:.*?)}|[[$1]]|g;

    # Trim any trailing <br />
    $mwcontent =~ s|<br\s*/>\s*$||g;

    return $mwcontent;
}

# -----------------------------------------------------------------------------
#  HTML loader functions

## @method @ load_step_version3($stepfile)
# Load a step file whose contents were written in a format compatible with course
# processor version 3.
#
# @param stepfile The name of the step file to load.
# @return The step title and body on success, undefs otherwise.
sub load_step_version3 {
    my $stepfile = shift;

    $logger -> print($logger -> DEBUG, "Processing step $stepfile as a version 3 step.");

    my $root = eval { HTML::TreeBuilder -> new_from_file($stepfile) };
    die "FATAL: Unable to load and parse $stepfile: $@" if($@);
    $root = $root -> elementify();

    # find the page body
    my $body = $root -> look_down("id", "page-body");
    if(!$body) {
        $logger -> print($logger -> DEBUG, "Unable to locate 'page-body' div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # Try to get the title
    my $titleelem = $body -> look_down("_tag", "h1",
                                       "class", "main");
    if(!$titleelem) {
        $logger -> print($logger -> DEBUG, "Unable to locate step title in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }
    my $titletext = $titleelem -> as_text();

    # And now the content div
    my $content = $body -> look_down("id", "content");
    if(!$content) {
        $logger -> print($logger -> DEBUG, "Unable to locate content div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # get the contents
    my $realcontent = $content -> as_HTML();
    $realcontent =~ s|^<div id="content">(.*)</div>$|$1|s;

    # must explicitly delete the html tree to prevent leaks
    $root -> delete();

    return ($titletext, $realcontent);
}


## @method @ load_step_version2($stepfile)
# Load a step file whose contents were written in a format compatible with course
# processor version 2.
#
# @param stepfile The name of the step file to load.
# @return The step title and body on success, undefs otherwise.
sub load_step_version2 {
    my $stepfile = shift;

    $logger -> print($logger -> DEBUG, "Processing step $stepfile as a version 2 step.");

    my $root = eval { HTML::TreeBuilder -> new_from_file($stepfile) };
    die "FATAL: Unable to load and parse $stepfile: $@" if($@);
    $root = $root -> elementify();

    # Try to get the title
    my $titleelem = $root -> find("title");
    if(!$titleelem) {
        $logger -> print($logger -> DEBUG, "Unable to locate step title in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }
    my $titletext = $titleelem -> as_text();

    # And now the content div
    my $content = $root -> look_down("id", "content");
    if(!$content) {
        $logger -> print($logger -> DEBUG, "Unable to locate content div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # get the contents
    my $realcontent = $content -> as_HTML();
    $realcontent =~ s|^<div id="content">(.*)</div>$|$1|s;

    # must explicitly delete the html tree to prevent leaks
    $root -> delete();

    # Many version 2 steps used a centered table for layout (Azathoth knows why I did it that way...)
    # Remove the horror, and for Hastur's sake do it case insensitive, as some of the html is in bloody allcaps.
    $realcontent =~ s|^\s*<center>\s*<table width="\d+%">\s*<tr><td>\s*(.*)\s*</td></tr>\s*</table>\s*(?:&nbsp;)?\s*</center>\s*(?:&nbsp;)?\s*|$1|si;

    # And has some odd <div><ul>...</ul></div> setups..
    $realcontent =~ s|<div>\s*(<ul>.*?</ul>)\s*(?:</div>)?|$1|gis;
    $realcontent =~ s|<div>\s*(<ol>.*?</ol>)\s*(?:</div>)?|$1|gis;

    # Lots of <center></center> going on, try to clean them up a bit
    $realcontent =~ s|<center>\s*</center>||gis;
    $realcontent =~ s|<center>|<div style="text-align: center">|gis;
    $realcontent =~ s|</center>|</div>|gis;

    # And random empty divs...
    $realcontent =~ s|<div>\s*</div>||gis;

    $logger -> print($logger -> DEBUG, "Content for $stepfile (title $titletext) is:\n$realcontent\n");

    return ($titletext, $realcontent);
}


## @method @ load_step_version1($stepfile)
# Load a step file in a completely naive way - just loading the title and whole
# body contents. This is probably never what is needed!
#
# @param stepfile The name of the step file to load.
# @return The step title and body on success, undefs otherwise.
sub load_step_version1 {
    my $stepfile = shift;

    # Do nothing if the naive loader is disabled.
    if(!$allow_naive) {
        $logger -> print($logger -> DEBUG, "Naive loader is disabled, aborting step load.");
        return (undef, undef);
    }

    $logger -> print($logger -> WARNING, "Processing step $stepfile using naive loader. THIS IS PROBABLY NOT WHAT YOU WANT TO HAPPEN!");

    my $root = eval { HTML::TreeBuilder -> new_from_file($stepfile) };
    die "FATAL: Unable to load and parse $stepfile: $@" if($@);
    $root = $root -> elementify();

    # Try to get the title
    my $titleelem = $root -> find("title");
    if(!$titleelem) {
        $logger -> print($logger -> DEBUG, "Unable to locate step title in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }
    my $titletext = $titleelem -> as_text();

    # And now the content div
    my $content = $root -> find("body");
    if(!$content) {
        $logger -> print($logger -> DEBUG, "Unable to locate content div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # get the contents
    my $realcontent = $content -> as_HTML();
    $realcontent =~ s|^<body.*>(.*)</body>$|$1|s;

    # must explicitly delete the html tree to prevent leaks
    $root -> delete();

    $logger -> print($logger -> DEBUG, "Converted content for $stepfile:\n$realcontent\n");

    return ($titletext, $realcontent);
}


# -----------------------------------------------------------------------------
#  Scanning functions

## @fn $ scan_glossary($glossarydir)
# Load the contents of the course glossary into memory, so that the step loader
# can replace glossary terms on the fly.
#
# @param glossarydir The path to the glossary directory.
# @return The number of glossary terms loaded.
sub scan_glossary {
    my $glossarydir = shift;
    my $termcount   = 0;

    # If the glossary directory does not exist, do nothing.
    return 0 if(!-d $glossarydir);

    foreach my $glosfile ("a".."z", "digits", "symbols") {
        $termcount += load_legacy_glossary(path_join($glossarydir, "$glosfile.html"), $course_glosshash)
            if(-f path_join($glossarydir, "$glosfile.html"));
    }

    return $termcount;
}


## @fn @ load_step_file($wikih, $stepfile, $themedir, $media)
# Load the contents of the specified step file, converting as much as possible
# back into wiki markup.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param stepfile The step file to load into memory.
# @param themedir The name of the current theme directory.
# @param moddir   The name of the current module directory.
# @param media    A refrence to an array to store media file links in.
# @return An array containing the step title and content on success, undefs otherwise.
sub load_step_file {
    my $wikih    = shift;
    my $stepfile = shift;
    my $themedir = shift;
    my $moddir   = shift;
    my $media    = shift;

    $logger -> print($logger -> DEBUG, "Processing step $stepfile.");

    # Try each loader version on the file until one understands it, or it can't be parsed.
    my ($titletext, $realcontent) = load_step_version3($stepfile);
    if(!$titletext || !$realcontent) {
        $logger -> print($logger -> DEBUG, "Version 3 loader failed, trying Version 2.");
        ($titletext, $realcontent) = load_step_version2($stepfile);

        if(!$titletext || !$realcontent) {
            $logger -> print($logger -> DEBUG, "Version 2 loader failed, trying Version 1.");
            ($titletext, $realcontent) = load_step_version1($stepfile);

            if(!$titletext || !$realcontent) {
                $logger -> print($logger -> WARNING, "All loaders failed to parse step $stepfile, unable to process this step.");
                return (undef, undef);
            }
        }
    }

    my $mwcontent = convert_content($wikih, $realcontent, $titletext, $themedir, $moddir, $media);

    # now try to deal with popups
    $mwcontent =~ s|<span class="twpopup">(.*?)<span class="twpopup-inner">([a-zA-Z0-9+=/\n ]+)</span>\s*</span>|fix_twpopup($wikih, $1, $2, $media)|ges;
    $mwcontent =~ s|<span class="twpopup-fixed">(.*?)<span class="twpopup-inner">([a-zA-Z0-9+=/\n ]+)</span>\s*</span>|fix_twpopup($wikih, $1, $2, $media, 1)|ges;

    return ($titletext, $mwcontent);
}


## @fn $ scan_module_directory($wikih, $fullpath, $themedir, $moddir, $module, $media)
# Scan the specified module directory for steps, concatenating their contents into
# a single wiki page.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param fullpath The path to the module directory.
# @param themedir The name of the current theme directory.
# @param moddir   The name of the module directory.
# @param module   The title of the module.
# @param media    A refrence to an array to store media file links in.
# @return A wiki link for the module on success, undef otherwise.
sub scan_module_directory {
    my $wikih    = shift;
    my $fullpath = shift;
    my $themedir = shift;
    my $moddir   = shift;
    my $module   = shift;
    my $media    = shift;

    $logger -> print($logger -> DEBUG, "Scanning directory $module for steps.");

    # Get the list of steps in the directory
    my $cwd = getcwd();
    chdir($fullpath)
        or die "FATAL: Unable to change to $fullpath: $!\n";

    my @stepnames = glob("step*.html");

    # We need steps to do anything...
    if(!scalar(@stepnames)) {
        $logger -> print($logger -> WARNING, "Module directory '$fullpath' contains no step files!");
        return undef;
    }

    my @sorted = sort sort_step_func @stepnames;

    # Now process each step into an appropriate page
    my $pagecontent = "";
    foreach my $stepname (@sorted) {
        my ($title, $content) = load_step_file($wikih, path_join($fullpath, $stepname), $themedir, $moddir, $media);

        # Make the step in wiki format
        $pagecontent .= "== $title ==\n$content\n" if($title && $content);
    }

    # Add the course nav block
    $pagecontent .= "\n<noinclude>{{$namespace:CourseNav}}</noinclude>\n";

    # Do the edit and then return a link to the new module page.
    wiki_edit_page($wikih, $namespace, $module, \$pagecontent, $dryrun);

    chdir($cwd);

    return wiki_link($namespace.':'.$module, $module);
}


## @fn void check_theme_directory($wikih, $fullpath, $dirname, $mediahash)
# Check whether the specified directory is a theme directory (it contains a
# metadata.xml file) and if it is, store the theme metadata
#
# @param wikih     A reference to a Mediawiki::API object.
# @param fullpath  The path to the theme directory to process.
# @param dirname   The name of the theme directory.
# @param mediahash A reference to a hash to store media links in.
sub check_theme_directory {
    my $wikih     = shift;
    my $fullpath  = shift;
    my $dirname   = shift;

    if($only_theme && $dirname ne $only_theme) {
        $logger -> print($logger -> DEBUG, "Skipping directory $dirname as it does not match theme restriction.");
        return undef;
    }

    $logger -> print($logger -> DEBUG, "Processing directory $dirname.");

    # Do we have a metadata file? If not, give up...
    if(!-f path_join($fullpath, "metadata.xml")) {
        $logger -> print($logger -> WARNING, "Skipping non-theme directory $dirname (metadata not found in directory.)");
        return undef;
    }

    # load the metadata, converting it as needed
    my ($xmltree, $metadata) = load_legacy_metadata($fullpath, $dirname);
    if(!$xmltree) {
        $logger -> print($logger -> WARNING, "Skipping directory $dirname (metadata loading failed.)");
        return undef;
    }

    $logger -> print($logger -> DEBUG, "Directory $dirname contains the theme '".$xmltree -> {"theme"} -> {"title"}."', recording for later scanning.");
    $course_xmltree -> {$dirname} = $xmltree;
    $course_mdata -> {$dirname} = $metadata;
}


## @fn void scan_theme_directory($wikih, $fullpath, $dirname, $mediahash)
# Process the contents of a theme directory.
#
# @param wikih     A reference to a Mediawiki::API object.
# @param fullpath  The path to the theme directory to process.
# @param dirname   The name of the theme directory.
# @param mediahash A reference to a hash to store media links in.
sub scan_theme_directory {
    my $wikih     = shift;
    my $fullpath  = shift;
    my $dirname   = shift;
    my $mediahash = shift;

    $logger -> print($logger -> DEBUG, "Processing theme $dirname.");

    # Process each module in order.
    my @modnames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b"
                               if(!$course_xmltree -> {$dirname} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} ||
                                  !$course_xmltree -> {$dirname} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});

                           return ($course_xmltree -> {$dirname} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"}
                                   <=>
                                   $course_xmltree -> {$dirname} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
                         }
                         keys(%{$course_xmltree -> {$dirname} -> {"theme"} -> {"module"}});

    my $themepage  = "== ".$config -> {"wiki2course"} -> {"modules_title"}." ==\n";
    my $thememedia = [];

    # scan modules inside the theme directory, storing the steps as we go.
    foreach my $module (@modnames) {
        my $link = scan_module_directory($wikih,
                                         path_join($fullpath, $module),
                                         $dirname,
                                         $module,
                                         $course_xmltree -> {$dirname} -> {"theme"} -> {"module"} -> {$module} -> {"title"},
                                         $thememedia);

        $themepage .= "$link<br />\n" if($link);
    }

    $themepage .= "\n== ".$config -> {"wiki2course"} -> {"metadata"}." ==\n<source lang=\"xml\" style=\"emacs\">\n".$course_mdata -> {$dirname}."</source>\n\n<noinclude>{{$namespace:CourseNav}}</noinclude>\n";

    # Check the metadata for images
    my @mdimages = $course_mdata -> {$dirname} =~ m|<img\s+(.*?)>|gs;
    if(scalar(@mdimages)) {
        $logger -> print($logger -> DEBUG, "Got ",scalar(@mdimages)," images in metadata");

        # Change to the theme dir, as image sources will be relative
        my $cwd = getcwd();
        chdir $fullpath
            or die "FATAL: Unable to change to directory '$fullpath': $!\n";

        foreach my $mdimg (@mdimages) {
            $logger -> print($logger -> DEBUG, "Processing '$mdimg'");

            # Can we get a sources?
            my ($imgsrc) = $mdimg =~ /src="(.*?)"/;

            if($imgsrc) {
                my $outname = fix_media_name($imgsrc);
                $logger -> print($logger -> DEBUG, "Found image in metadata: $imgsrc storing as $outname");

                my $errs = wiki_upload_media($wikih, $imgsrc, $outname, $dryrun);
                $logger -> print($logger -> WARNING, $errs) if($errs);

                # store the media link for inclusion in the media page later
                push(@$thememedia, wiki_link("File:$outname"));

            } else {
                $logger -> print($logger -> WARNING, "Malformed image <img $mdimg/> - no source found!");
            }
        }

        chdir $cwd;
    }

    # store the media hash if we have any entries
    $mediahash -> {$course_xmltree -> {$dirname} -> {"theme"} -> {"title"}} = $thememedia
        if(scalar(@$thememedia));

    # Add the theme page...
    wiki_edit_page($wikih, $namespace, $course_xmltree -> {$dirname} -> {"theme"} -> {"title"}, \$themepage, $dryrun);

    return wiki_link($namespace.':'.$course_xmltree -> {$dirname} -> {"theme"} -> {"title"}, $course_xmltree -> {$dirname} -> {"theme"} -> {"title"});
}


# -----------------------------------------------------------------------------
#  Generation code

## @fn void make_mediapage($wikih, $media)
# Create and upload a media page for the course. This will create a page listing
# all media uploaded to the wiki while importing the course.
#
# @param wikih A reference to a Mediawiki::API object.
# @param media A reference to a hash to store media links in.
sub make_mediapage {
    my $wikih = shift;
    my $media = shift;

    my $mediapage = "";
    # Go through each theme in the media hash, building a list of its files.
    foreach my $theme (sort(keys(%{$media}))) {
        $mediapage .= "== $theme ==\n";
        foreach my $link (@{$media -> {$theme}}) {
            $mediapage .= "$link<br />\n";
        }
        $mediapage .= "\n";
    }

    # Add the course nav block
    $mediapage .= "\n<noinclude>{{$namespace:CourseNav}}</noinclude>\n";

    # and do the page edit.
    wiki_edit_page($wikih, $namespace, $config -> {"wiki2course"} -> {"media_page"}, \$mediapage, $dryrun);
}


## @fn void make_coursedata($wikih, $themes, $coursemap)
# Create the course data page in the wiki.
#
# @param wikih     A reference to a Mediawiki::API object.
# @param themes    A string containing the list of theme links.
# @param coursemap A string containing the course map html.
sub make_coursedata {
    my $wikih     = shift;
    my $themes    = shift;
    my $coursemap = shift;

    if($only_theme) {
        $logger -> print($logger -> DEBUG, "Theme-restricted import is active, skipping coursedata page.");
    } else {
        $logger -> print($logger -> DEBUG, "Writing coursedata page.");

        # Horribly messy concatenation of all the page data
        my $cdpage = wiki_link($namespace.":".$config -> {"wiki2course"} -> {"course_page"}, "View ".lc($config -> {"wiki2course"} -> {"course_page"})." page")."\n".
            "== ".$config -> {"wiki2course"} -> {"themes_title"}." ==\n".
            $themes."\n".
            "== Resources ==\n".
            wiki_link($namespace.":".$config -> {"wiki2course"} -> {"media_page"}, "Media")."\n".
            "\n== ".$config -> {"wiki2course"} -> {"metadata"}." ==\n".
            "<source lang=\"xml\" style=\"emacs\">\n".
            "<course version=\"\">\n".
            "    <courseinfo title=\"\" splash=\"\" type=\"\" width=\"\" height=\"\"><![CDATA[\n".
            "    ]]></courseinfo>\n".
            ($coursemap ? "<maps><map><![CDATA[$coursemap]]></map></maps>\n" : "").
            "</course>\n</source>\n\n<noinclude>{{$namespace:CourseNav}}</noinclude>\n";

        # and do the page edit.
        wiki_edit_page($wikih, $namespace, ucfirst($config -> {"wiki2course"} -> {"data_page"}), \$cdpage, $dryrun);
    }
}


## @fn void make_coursenav($wikih, $metadata)
# Generate the course navigation page in the wiki.
#
# @param wikih    A reference to a MediaWiki::API object.
# @param metadata A reference to a hash containing the course metadata.
sub make_coursenav {
    my $wikih    = shift;
    my $metadata = shift;

    if($only_theme) {
        $logger -> print($logger -> DEBUG, "Theme-restricted import is active, skipping course nav page.");
    } else {
        $logger -> print($logger -> DEBUG, "Writing course navigation.\nMetadata is:\n".Dumper([$metadata]));

        # The start of the navbox is easy...
        my $coursenav = "{{Navbox course\n|support = [[$namespace:TODO]]{{dot}} [[$namespace:Image Source]]{{dot}} [[$namespace:Anim Source]]\n".
            "| cdpage = $namespace:".ucfirst($config -> {"wiki2course"} -> {"data_page"})."\n";

        # Now generate the themes and modules. This is nastier...
        my @themenames =  sort { die "Attempt to sort theme without indexorder while comparing $a and $b"
                               if(!$metadata -> {$a} -> {"theme"} -> {"indexorder"} ||
                                  !$metadata -> {$b} -> {"theme"} -> {"indexorder"});

                                 return ($metadata -> {$a} -> {"theme"} -> {"indexorder"}
                                         <=>
                                         $metadata -> {$b} -> {"theme"} -> {"indexorder"});
        }
        keys(%{$metadata});

        for(my $tnum = 0; $tnum < scalar(@themenames); ++$tnum) {
            $coursenav .= "| theme".($tnum + 1)." = [[$namespace:".$metadata -> {$themenames[$tnum]} -> {"theme"} -> {"title"}."]]\n";

            my @modnames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b"
                                       if(!$metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} ||
                                          !$metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});

                                   return ($metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"}
                                           <=>
                                           $metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
            }
            keys(%{$metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"}});

            my $namelist = "";
            foreach my $mod (@modnames) {
                $namelist .= "{{dot}} " if($namelist);
                $namelist .= "[[$namespace:".$metadata -> {$themenames[$tnum]} -> {"theme"} -> {"module"} -> {$mod} -> {"title"}."]]";
            }
            $coursenav .= "| modules".($tnum + 1)." = $namelist\n";
        }

        $coursenav .= "}}";

        wiki_edit_page($wikih, $namespace, "CourseNav", \$coursenav, $dryrun);
    } # if($only_theme) else
}


## @fn void make_course($wikih)
# Create (or update) the course page in the wiki.
#
# @param wikih A reference to a Mediawiki::API object.
sub make_course {
    my $wikih = shift;

    if($only_theme) {
        $logger -> print($logger -> DEBUG, "Theme-restricted import is active, skipping coursedata page.");
    } else {
        $logger -> print($logger -> DEBUG, "Writing course page.");

        my $course = "== Development resources ==\n".
            "[[$namespace:".ucfirst($config -> {"wiki2course"} -> {"data_page"})."]]<br />\n".
            "[[$namespace:CourseNav]]<br />\n".
            "[[$namespace:TODO]]\n\n".
            "== Source data ==\n".
            "[[$namespace:Anim Source]]<br />\n".
            "[[$namespace:Image Source]]<br />\n\n<noinclude>{{$namespace:CourseNav}}</noinclude>\n";

        wiki_edit_page($wikih, $namespace, ucfirst($config -> {"wiki2course"} -> {"course_page"}), \$course, $dryrun);
    }
}

# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

# Process the command line
GetOptions('course|c=s'     => \$coursedir,
           'username|u=s'   => \$username,
           'password|p=s'   => \$password,
           'dry-run!'       => \$dryrun,
           'allow-naive!'   => \$allow_naive,
           'force!'         => \$force,
           'wiki|w=s'       => \$apiurl,
           'uploadurl=s'    => \$uploadurl,
           'namespace|n=s'  => \$namespace,
           'only-theme|t=s' => \$only_theme,
           'config|g=s'     => \$configfile,
           'pid=s'          => \$pidfile,
           'verbose|v+'     => \$verbose,
           'quiet|q!'       => \$quiet,
           'help|?|h'       => \$help,
           'man'            => \$man) or pod2usage(2);
if(!$help && !$man) {
    die "FATAL: No course directory specified.\n" if(!$coursedir);
    die "FATAL: No namespace specified.\n" if(!$namespace);
    die "FATAL: No username specified.\n" if(!$username);
}
pod2usage(-verbose => 2) if($man);
pod2usage(-verbose => 0) if($help || !$username);

# Before doing any real work, write the PID if needed.
write_pid($pidfile) if($pidfile);

print "course2wiki.pl version ",get_version("course2wiki")," started.\n";

# set up the logger and configuration data
$logger -> set_verbosity($verbose);
$config = load_config($configfile, $default_config, "wiki2course", $logger);

# Override the api and uploadurl if set on the command like
$config -> {"wiki2course"} -> {"api_url"}    = $apiurl if($apiurl);
$config -> {"wiki2course"} -> {"upload_url"} = $uploadurl if($uploadurl);

die "FATAL: No wiki API URL has been specified either on the command line or in your configuration file. Unable to continue.\n"
    unless($config -> {"wiki2course"} -> {"api_url"});

die "FATAL: No wiki upload URL has been specified either on the command line or in your configuration file. Unable to continue.\n"
    unless($config -> {"wiki2course"} -> {"upload_url"});

# Do we have a course directory to work on?
if(-d $coursedir) {
    # predict doom if the program is launched without dry-run and force
    doomsayer() unless($dryrun || $force);

    # If we don't have a password, prompt for it
    $password = get_password() if(!$password);

    # Get the show on the road...
    my $wikih = MediaWiki::API -> new({api_url => $config -> {"wiki2course"} -> {"api_url"} });

    # Set the upload url
    $wikih -> {"config"} -> {"upload_url"} = $config -> {"wiki2course"} -> {"upload_url"};

    # Now we need to get logged in so we can get anywhere
    wiki_login($wikih, $username, $password);

    # Check the specified namespace is valid
    die "FATAL: The specified namespace does not appear in the wiki. You must create the namespace before it can be used.\n"
        unless(wiki_valid_namespace($wikih, $namespace));


    $logger -> print($logger -> DEBUG, "Scanning for themes.");

    # Okay, now we hope the course is a course...
    opendir(CDIR, $coursedir)
        or die "FATAL: Unable to open course directory: $!\n";

    while(my $entry = readdir(CDIR)) {
        # skip anything that isn't a directory for now
        next if($entry =~ /^\.\.?$/ || !(-d path_join($coursedir, $entry)));

        check_theme_directory($wikih, path_join($coursedir, $entry), $entry);
    }
    closedir(CDIR);

    $logger -> print($logger -> DEBUG, "Theme scan complete. Metadata available:\n".Dumper([$course_xmltree])."\n");

    $logger -> print($logger -> DEBUG, "Loading glossary.");
    my $termcount = scan_glossary(path_join($coursedir, "glossary"));
    $logger -> print($logger -> DEBUG, "Loaded $termcount glossary terms.");

    $logger -> print($logger -> DEBUG, "Processing themes.");
    my $themelist = "";
    my $mediahash = { };
    foreach my $entry (keys(%{$course_xmltree})) {
        my $themelink = scan_theme_directory($wikih, path_join($coursedir, $entry), $entry, $mediahash);
        $themelist .= "$themelink<br />\n" if($themelink);
    }

    # check for a course index to push into the course metadata
    my $coursemap = extract_coursemap($wikih, $mediahash);

    # Make the media page
    make_mediapage($wikih, $mediahash);

    # Finish off the course page as much as possible
    make_coursedata($wikih, $themelist, $coursemap);

    # write the nav page
    make_coursenav($wikih, $course_xmltree);

    # and update the course page to make sure the link is correct
    make_course($wikih);

    print "Import finished.\n";

} else {
    die "FATAL: course directory $coursedir does not exist. Nothing to do.\n";
}


# THE END!
__END__

=head1 NAME

course2wiki - import a course into a wiki namespace.

=head1 SYNOPSIS

course2wiki [options]

 Options:
    --allow-naive            Allow the naive step loader to run if other
                             step loaders fail (defaults to disabled).
    -c, --course=PATH        The location of the course to import.
    --dry-run                Perform the import without updating the wiki.
    --force                  Suppress the startup warning and countdown.
    -g, --config=FILE        Use an alternative configuration file.
    -h, -?, --help           Brief help message.
    --man                    Full documentation.
    -n, --namespace=NAME     The namespace containing the course to export.
    -p, --password=PASSWORD  Password to provide when logging in. If this is
                             not provided, it will be requested at runtime.
    --pid=FILE               Write the process id to a file.
    -q, --quiet              Suppress all normal status output.
    -t, --only-theme         Only import the named theme from the course.
    -u, --username=NAME      The name to log into the wiki as.
    --uploadurl=URL          The location of the wiki's Special:Upload page.
    -v, --verbose            If specified, produce more progress output.
    -w, --wiki=APIURL        The url of the mediawiki API to use.

=head1 OPTIONS

=over 8

=item B<--allow-naive>

If set, the import script is allowed to fall back on a very naive step loader
(the title and body are pulled straight out of the html, potentially including
any navigation and overall layout elements defined in the page) if the other
step loaders fail to parse the step. This is generally not what you want to
happen, so the naive loader is disabled unless this flag is provided. Use it
with extreme caution, or you are likely to end up with a very messy import.

=item B<-c, --course>

I<This argument must be provided.> This argument tells the script where the
course to be imported is stored. The specified path should be the root of the
course (the directory containing the course themes).

=item B<--dry-run>

Perform the import process without updating the wiki. When the script is invoked
with this argument, it will go through the course pretending to import it into
the wiki without actually updating it. All actions that would be performed
are reported on the terminal so that the user can verify that the course would
be imported correctly. I<It is important that you run the importer with this
argument until you are certain the course will import correctly.> If the script
is invoked without this argument (and without the --force argument) it will
show a warning message and 5 second countdown before starting the import.

=item B<--force>

If specified, this will suppress the warning message and countdown shown when
the script is started without the --dry-run argument.

=item B<-g, --config>

Specify an alternative configuration file to use during importing. If not set,
the .courseprocessor.cfg file in the user's home directory will be used instead.

=item B<-h, -?, --help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<-n, --namespace>

I<This argument must be provided.> This argument identifies the namespace
containing the course you want to export, and it must correspond to a valid
namespace in the wiki. As ever, case is important here, so triple-check that
you have provided the namespace name in the correct case.

The namespace must already exist in the wiki before you can import a course
into it, this tool will not create a namespace for you!

=item B<-p, --password>

This argument is optional. If provided, the script will attempt to use the
specified password when logging into the wiki. Use of this argument is
B<very strongly discouraged in general use> - it is provided to allow the
export script to be called programmatically, and providing your password this
way can be a security risk (anyone looking over your shoulder could see the
plain text password on the command prompt, and the whole command line will be
saved in your shell history, including the password).

=item B<--pid>

If specified, the script will write its process ID to the file provided. This
is primarily needed to support the web interface.

=item B<-q, --quiet>

Suppresses all non-fatal output. If quiet is set, the script will not print
any status, warning, or debugging information to stdout regardless of the
verbosity setting. Fatal errors will still be printed to stderr as normal.

=item B<-t, --only-theme>

Restrict the import process to the named theme. No coursedata content will
be generated if this is specified, but it can be useful to import individual
themes into an existing course, or as part of incremental porting.

=item B<-u, --username>

I<This argument must be provided.> This argument specifies which username
should be used to log into the wiki. This must correspond to a valid wiki
user, and you will need to either provide the password using the --password
option described above, or you will be prompted to enter the password by
course2wiki.pl. If your username contains spaces, please ensure that you
either enclose the username in quotes, or replace any spaces with
underscores. Note that wiki usernames B<are case sensitive>, so check that
you use the correct case when specifying your username or the login will fail.

=item B<--uploadurl>

Specifies the location of the Special:Upload page in the target wiki. If not
provided, this will default to the upload page on the development wiki. If
you specify a different wiki with the --wiki argument you will almost certainly
need to specify your own uploadurl as well!

=item B<-v, --verbose>

Increase the verbosity of status reporting. By default (unless the quiet flag
is set), course2wiki.pl will only output warning messages during course import.
If you include -v on the command line, it will output warnings and notices.
For complete status information including debug messages, specify -v twice
(-v -v).

=item B<-w, --wiki>
This argument is optional. If provided, the script will use the MediaWiki API
script specified rather than the default DevWiki version.

=back

=head1 DESCRIPTION

=over 8

Please consult the Docs:course2wiki.pl documentation in the wiki for a full
description of this program.

=back

=cut
