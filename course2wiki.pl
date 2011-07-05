#!/usr/bin/perl -W

## @file
# Script to convert an APEcs/PEVEit course generated using previous
# versions of the course processor into a form suitable for importing
# into a wiki.
#
# For full documentation please see http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Course2wiki.pl
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0.0 (22 June 2011)
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
use Logger;
use Metadata;
use ProcessorVersion;
use Utils qw(load_file path_join find_bin write_pid get_password makedir load_config);
use MediaWiki::Wrap;

# Location of the API script in the default wiki.
use constant WIKIURL    => 'http://elearn.cs.man.ac.uk/devwiki/api.php';

# Location of the Special:Upload page in the wiki
use constant UPLOADURL  => 'http://elearn.cs.man.ac.uk/devwiki/index.php/Special:Upload';

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
my ($coursedir, $username, $password, $namespace, $dryrun, $force, $apiurl, $uploadurl, $verbose, $configfile, $pidfile, $quiet) = ('', '', '', '', 0, 0, WIKIURL, UPLOADURL, 0, '', '', 0);
my $man = 0;
my $help = 0;

# Global logger. Yes, I know, horrible, but it'd be being passed around /everywhere/ anyway
my $logger = new Logger();

# Likewise with the configuration object.
my $config;


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

    # Remove any path...
    $name =~ s|^.*?/([^/]+)$|$1|;

    # Prefix the name with the namespace if it isn't already
    $name = $namespace."_".$name if($name =~ /^${namespace}_/);

    return $name;
}


# -----------------------------------------------------------------------------
#  HTML fixing functions

## @fn $ fix_link($link, $text)
# Attempt to convert the specified link and text to [link] tag suitable for
# passing through to output handlers. This will only convert links that appear
# to be relative links to anchors in the course - any links to external
# resources are returned as-is.
#
# @param link The URL to process.
# @param text The text to show for the link.
# @return A string containing the link - either the [link] tag, or a <a> tag.
sub fix_link {
    my $link = shift;
    my $text = shift;

    # if the link looks absolute, or has no anchor return it as-is
    if($link =~ m|://| || $link !~ /#/) {
        return "<a href=\"$link\">$text</a>";

    # We have a relative anchored link, so convert to a [link] tag
    } else {
        my ($anchor) = $link =~ /#(.*)$/;
        return "[link to=\"$anchor\"]".$text."[/link]";
    }
}


## @fn $ fix_flash($wikih, $object)
# Pull the width, height, and flash file name out of a (probable) flash
# object/embed tag combination, and convert to an intermediate string that
# will get it through HTML::WikiConverter unscathed.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param object The text of the object/embed tags to process.
# @return A string containing the intermediate flash tag, or the original
#         object/embed combo.
sub fix_flash {
    my $wikih  = shift;
    my $object = shift;

    # Attempt to get the width, height, and flash file names
    my ($width)  = $object =~ /width="(\d+)"/;
    my ($height) = $object =~ /height="(\d+)"/;
    my ($flash)  = $object =~ /src="(.*?\.swf)"/;

    # If we have all three, it's probably a flash tag...
    if($width && $height && $flash) {
        my $outname = fix_media_name($flash);
        wiki_upload_media($wikih, $flash, $outname, $dryrun);

        return '{flash}file='.$outname.'|width='.$width.'|height='.$height.'{/flash}';
    }

    # otherwise return it as-is, we can't fix it.
    return "<div>$object</div>";
}


## @fn $ fix_twpopup($wikih, $title, $encdata)
# Convert a TWPopup span sequence into a <popup> tag.
#
# @param wikih   A reference to the MediaWiki::API wiki handle.
# @param title   The title string for the popup.
# @param encdata The Base64 encoded popup body.
# @return A string containing the <popup> tag.
sub fix_twpopup {
    my $wikih   = shift;
    my $title   = shift;
    my $encdata = shift;

    # Converting to mediawiki format will have killed the newlines in thebase64 encoded data, fix that
    $encdata =~ s/ /\n/g;

    # decode so that we can convert the content
    my $content = decode_base64($encdata);
    if($content) {
        $content = convert_content($wikih, $content);
    } else {
        $content = $encdata;
    }

    return "<popup title=\"$title\">$content</popup>";
}


## @fn $ fix_image($wikih, $imgattrs)
# Take the contents of an img tag and produce a mediawiki tag to
# take its place.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param imgattrs The image tag attribute list.
# @return An mediawiki image tag, or the original <img> if the imgattrs
#         can't be understood.
sub fix_image {
    my $wikih    = shift;
    my $imgattrs = shift;

    my ($imgname) = $imgattrs =~ /src="(.*?)"/;
    if(!$imgname) {
        $logger -> print($logger -> WARNING, "Malformed image <img $imgattrs/> - no source found!");
        return "<img $imgattrs/>";
    }

    # Upload image here...
    my $outname = fix_media_name($imgname);
    wiki_upload_media($wikih, $imgname, $outname, $dryrun);

    return "[[Image:$outname]]";
}


## @fn $ convert_content($wikih, $content)
# Convert the provided content from HTML to MediaWiki markup.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param content The html content to convert to MediaWiki markup.
# @return The converted content.
sub convert_content {
    my $wikih   = shift;
    my $content = shift;

    # Convert links with anchors to [target] and [link] as needed...
    $content =~ s|<a\s+name="(.*?)">\s*</a>|[target name="$1"]|g;
    $content =~ s|<a\s*href="(.*?)">(.*?)</a>|fix_link($1, $2)|ges;

    # Fix flash, stage 1
    $content =~ s|<div>(<object.*?</object>)</div>|fix_flash($wikih, $1)|ges;

    # Fix images
    $content =~ s|<div.*?><img\s+(.*?)></div>|fix_image($wikih, $1)|ges;

    # Do html conversion
    my $mw = new HTML::WikiConverter(dialect => 'MediaWiki');
    my $mwcontent = $mw -> html2wiki($content);

    # Fix flash, stage 2
    $mwcontent =~ s|{(/?flash)}|<$1>|g;

    # Trim any trailing <br/>
    $mwcontent =~ s|<br\s*/>\s*$||g;

    return $mwcontent;
}


# -----------------------------------------------------------------------------
#  Scanning functions

## @fn @ load_step_file($wikih, $stepfile)
# Load the contents of the specified step file, converting as much as possible
# back into wiki markup.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param stepfile The step file to load into memory.
# @return An array containing the step title and content on success, undefs otherwise.
sub load_step_file {
    my $wikih    = shift;
    my $stepfile = shift;

    my $root = eval { HTML::TreeBuilder -> new_from_file($stepfile) };
    die "FATAL: Unable to load and parse $stepfile: $@" if($@);
    $root = $root -> elementify();

    # find the page body
    my $body = $root -> look_down("id", "page-body");
    if(!$body) {
        $logger -> print($logger -> WARNING, "Unable to locate 'page-body' div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # Try to get the title
    my $titleelem = $body -> look_down("_tag", "h1",
                                       "class", "main");
    if(!$titleelem) {
        $logger -> print($logger -> WARNING, "Unable to locate step title in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }
    my $titletext = $titleelem -> as_text();

    # And now the content div
    my $content = $body -> look_down("id", "content");
    if(!$content) {
        $logger -> print($logger -> WARNING, "Unable to locate content div in $stepfile. Unable to load step.");
        $root -> delete();
        return (undef, undef);
    }

    # get the contents
    my $realcontent = $content -> as_HTML();
    $realcontent =~ s|^<div id="content">(.*)</div>$|$1|s;

    my $mwcontent = convert_content($wikih, $realcontent);

    # now try to deal with popups
    $mwcontent =~ s|<span class="twpopup">(.*?)<span class="twpopup-inner">([a-zA-Z0-9+= ]+)</span></span>|fix_twpopup($wikih, $1, $2)|ges;

    # must explicitly delete the html tree to prevent leaks
    $root -> delete();

    return ($titletext, $mwcontent);
}


## @fn $ scan_module_directory($wikih, $fullpath, $module)
# Scan the specified module directory for steps, concatenating their contents into
# a single wiki page.
#
# @param wikih    A reference to the MediaWiki::API wiki handle.
# @param fullpath The path to the module directory.
# @param module   The title of the module.
# @return A wiki link for the module on success, undef otherwise.
sub scan_module_directory {
    my $wikih    = shift;
    my $fullpath = shift;
    my $module   = shift;

    # Get the list of steps in the directory
    my $cwd = getcwd();
    chdir($fullpath)
        or die "FATAL: Unable to change to $fullpath: $!\n";

    my @stepnames = glob("step*.html");

    # We need steps to do anything...
    return undef if(!scalar(@stepnames));

    my @sorted = sort sort_step_func @stepnames;

    # Now process each step into an appropriate page
    my $pagecontent = "";
    foreach my $stepname (@sorted) {
        my ($title, $content) = load_step_file($wikih, path_join($fullpath, $stepname));

        # Make the step in wiki format
        $pagecontent .= "== $title ==\n$content\n" if($title && $content);
    }

    # Do the edit and then return a link to the new module page.
    wiki_edit_page($wikih, $namespace, $module, \$pagecontent, $dryrun);

    chdir($cwd);

    return wiki_link($namespace.':'.$module, $module);
}


## @fn $ scan_theme_directory($wikih, $fullpath, $dirname)
# Check whether the specified directory is a theme directory (it contains a
# metadata.xml file) and if it is, process its contents.
sub scan_theme_directory {
    my $wikih    = shift;
    my $fullpath = shift;
    my $dirname  = shift;

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

    # Process each module in order.
    my @modnames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b"
                               if(!$xmltree -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} ||
                                  !$xmltree -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});

                           return ($xmltree -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"}
                                   <=>
                                   $xmltree -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
                         }
                         keys(%{$xmltree -> {"theme"} -> {"module"}});

    my $themepage = "== Modules ==\n";
    foreach my $module (@modnames) {
        my $link = scan_module_directory($wikih, path_join($fullpath, $module), $xmltree -> {"theme"} -> {"module"} -> {$module} -> {"title"});
        $themepage .= "$link<br />\n" if($link);
    }

    $themepage .= "\n== Metadata ==\n<source lang=\"xml\" style=\"emacs\">\n$metadata</source>\n";

    # Check the metadata for images
    my @mdimages = $metadata =~ m|<img\s+(.*?)>|gs;
    if(scalar(@mdimages)) {
        print "Got ",scalar(@mdimages)," images in metadata\n";

        # Change to the theme dir, as image sources will be relative
        my $cwd = getcwd();
        chdir $fullpath
            or die "FATAL: Unable to change to directory '$fullpath': $!\n";

        foreach my $mdimg (@mdimages) {
            print "Processing '$mdimg'\n";

            # Can we get a sources?
            my ($imgsrc) = $mdimg =~ /src="(.*?)"/;

            if($imgsrc) {
                my $outname = fix_media_name($imgsrc);
                wiki_upload_media($wikih, $imgsrc, $outname, $dryrun);
            } else {
                $logger -> print($logger -> WARNING, "Malformed image <img $mdimg/> - no source found!");
            }
        }

        chdir $cwd;
    }

    # Add the theme page...
    wiki_edit_page($wikih, $namespace, $xmltree -> {"theme"} -> {"title"}, \$themepage, $dryrun);

    return wiki_link($namespace.':'.$xmltree -> {"theme"} -> {"title"}, $xmltree -> {"theme"} -> {"title"});
}


# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

# Process the command line
GetOptions('course|c=s'    => \$coursedir,
           'username|u=s'  => \$username,
           'password|p=s'  => \$password,
           'dry-run!'      => \$dryrun,
           'force!'        => \$force,
           'wiki|w=s'      => \$apiurl,
           'uploadurl=s'   => \$uploadurl,
           'namespace|n=s' => \$namespace,
           'config|g=s'    => \$configfile,
           'pid=s'         => \$pidfile,
           'verbose|v+'    => \$verbose,
           'quiet|q!'      => \$quiet,
           'help|?|h'      => \$help,
           'man'           => \$man) or pod2usage(2);
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

# Do we have a course directory to work on?
if(-d $coursedir) {
    # predict doom if the program is launched without dry-run and force
    doomsayer() unless($dryrun || $force);

    # If we don't have a password, prompt for it
    $password = get_password() if(!$password);

    # Get the show on the road...
    my $wikih = MediaWiki::API -> new({api_url => $apiurl });

    # Set the upload url if needed
    $wikih -> {"config"} -> {"upload_url"} = $uploadurl if($uploadurl);

    # Now we need to get logged in so we can get anywhere
    wiki_login($wikih, $username, $password);

    # Check the specified namespace is valid
    die "FATAL: The specified namespace does not appear in the wiki. You must create the namespace before it can be used.\n"
        unless(wiki_valid_namespace($wikih, $namespace));

    # Okay, now we hope the course is a course...
    opendir(CDIR, $coursedir)
        or die "FATAL: Unable to open course directory: $!\n";

    my $themelist = "== Themes ==\n";
    while(my $entry = readdir(CDIR)) {
        # skip anything that isn't a directory for now
        next if($entry =~ /^\.\.?$/ || !(-d path_join($coursedir, $entry)));

        my $themelink = scan_theme_directory($wikih, path_join($coursedir, $entry), $entry);
        $themelist .= "$themelink<br />\n" if($themelink);
    }

    # check for a course index to push into the course metadata
#    my $coursemap = extract_coursemap();

    # Finish off the course page as much as possible
#    make_coursedata($themelist, $coursemap);

}

print "Import finished.\n";


# THE END!
__END__
