#!/usr/bin/perl -W

## @file
# Script to export the contents of a course namespace in the APEcs
# development wiki to html files in a standard APEcs course data
# structure suitable for passing to processor.pl.
#
# For full documentation please see http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Wiki2course.pl
#
# @copy 2010, Chris Page &lt;chris@starforge.co.uk&gt;
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

# System modules
#use Data::Dumper;
use Digest;
use Encode qw(encode encode_utf8);
use File::HomeDir;
use Getopt::Long;
use MediaWiki::API;
use MIME::Base64;
use Pod::Usage;
use XML::Simple;

# Local modules
use lib ("$path/modules"); # Add the script path for module loading
use lib ("/var/www/webperl"); # and to webperl
use Logger;
use ProcessorVersion;
use Utils qw(save_file path_join find_bin write_pid);
use MCPUtils qw(get_password makedir load_config);
use MediaWiki::Wrap;

# Constants used in various places in the code
# The maximum number of levels of page transclusion that may be processed
use constant MAXLEVEL => 5;

# default settings
my $default_config = { course_page   => "Course",
                       data_page     => "coursedata",
                       themes_title  => "Themes",
                       modules_title => "Modules",
                       metadata      => "Metadata",
                       media_page    => "Media"
    };

# various globals set via the arguments
my ($retainold, $quiet, $basedir, $username, $password, $namespace, $apiurl, $fileurl, $convert, $verbose, $mediadir, $configfile, $pidfile) = ('', '', '', '', '', '', '', '', '', 0, 'media', '', '');
my $man = 0;
my $help = 0;

# Global logger. Yes, I know, horrible, but it'd be being passed around /everywhere/ anyway
my $logger = new Logger();

# Likewise with the configuration object.
my $config;

# A global anchor hash is needed to keep track of defined targets
my $anchorhash = {};


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

## @fn void find_bins($config)
# Attempt to locate the external binaries the exporter relies on to operate. This
# function will store the location of the binaries used by this script inside the
# 'paths' section of the supplied config.
#
# @param config The configuration hash to store the paths in.
sub find_bins {
    my $config = shift;

    $config -> {"paths"} -> {"rm"} = find_bin("rm")
        or die "FATAL: Unable to locate 'rm' in search paths.\n";

}


# -----------------------------------------------------------------------------
#  Step processing functions

## @fn $ process_generated_media($wikih, $type, $path, $filename)
# Download the specified generated media file, and store it in the media/generated
# directory, returning a suitable replacement string.
#
# @param wikih A reference to the wiki API handle object.
# @param type  The media type (should be one of "math" or "thumb")
# @param path  The path to the image excluding everything before and including the
#              type directory - so for /devwiki/images/math/E/Ec/abcdef0912384.png,
#              this will be /E/Ec/abcdef0912384.png
# @param mediahash A reference to a hash of media files in the media directory.
# @return A replacement string containing the source relative to the exported
#         html files.
sub process_generated_media {
    my $wikih     = shift;
    my $type      = shift;
    my $path      = shift;
    my $mediahash = shift;

    my $dir = path_join($basedir, $mediadir, "generated", $type);

    my ($filename) = $path =~ m{/([^/]+)$};
    $logger -> print($logger -> NOTICE, "Fetching generated file ".$type.$path." to $dir/$filename") unless($quiet);

    my $url = path_join($wikih -> {"siteinfo"} -> {$type."path"}, $path);
    if(makedir($dir, $logger, 1)) {
        my $error = wiki_download_direct($wikih, $url, path_join($dir, $filename));

        $logger -> print($logger -> WARNING, $error) if(!$quiet && $error);

        # Record the file for later verification.
        my $outname = "generated/$type/$filename";
        $mediahash -> {lc($outname)} = $outname;

        return "src=\"../../$mediadir/$outname\"";
    } else {
        die "FATAL: Unable to create directory $dir: $@\n";
    }
}


## @fn $ check_media_file($wikih, $filename, $mediahash)
# Determine whether the specified file is present in the media directory. This will attempt
# to locate the named file in the media hash, and if it can not find an entry for it
# it will print a warning to that effect and just pass through the filename. If an entry
# can be found, but the case of the stored and checked name do not match it will correct
# the case to the stored case.
#
# @param wikih     A reference to the mediawiki API object.
# @param filename  The name of the file to check.
# @param mediahash A reference to a hash of media files in the media directory.
# @return The checked file, including relative path to the media directory
sub check_media_file {
    my $wikih     = shift;
    my $filename  = shift;
    my $mediahash = shift;

    $logger -> print($logger -> DEBUG, "Checking media file $filename against the media file list.") unless($quiet);

    # do we have a remote match at all?
    if($mediahash -> {lc($filename)}) {
        # we have a match, do the cases match?
        if($mediahash -> {lc($filename)} ne $filename) {
            # No, fix that...
            $logger -> print($logger -> NOTICE, "Correcting case for media file '$filename' (should be '".$mediahash -> {lc($filename)}."'.") unless($quiet);
            $filename = $mediahash -> {lc($filename)};
        } else {
            $logger -> print($logger -> DEBUG, "Media file '$filename' is present in the media file list.") unless($quiet);
        }
    } else {
        $logger -> print($logger -> WARNING, "Unable to locate '$filename' in the media directory, attempting to fetch.") unless($quiet);

        # try to get the file, if we can then store it for later use
        my $error = wiki_download($wikih, $filename, path_join($basedir, $mediadir, $filename));
        if(!$error) {
            $mediahash -> {$filename} = $filename;
            $logger -> print($logger -> WARNING, "Fetched '$filename'. Consider adding it to your media page to avoid this warning.") unless($quiet);
        } else {
            $logger -> print($logger -> WARNING, "Unable fetch '$filename': $error") unless($quiet);
        }
    }

    return "\"../../$mediadir/$filename\"";
}


## @fn $ broken_media_link($filename, $page)
# Generate a warning message to the log, and an error message to place into the output
# page, to indicate that a link to a non-existent file has been encountered in the
# text.
#
# @param filename The name of the file that does not exist.
# @param page     The page the link is on.
# @return An error message to place in the page instead of the file upload link.
sub broken_media_link {
    my $filename = shift;
    my $page     = shift;

    $logger -> print($logger -> WARNING, "Request for non-existent file $filename in $page.") unless($quiet);

    return "<span class=\"error\">No file avilable for $filename. Please check the source data for this step.</span>";
}


## @fn $ process_link($linkref, $title)
# Convert a link within the course namespace into a [link to="" /] tag.
#
# @param linkref The location being linked to, may be a module page or an anchor in it.
# @param title   The title to show in the link, if not set uses the linkref
# @return The link tag to replace the mediawiki link with.
sub process_link {
    my $linkref = shift;
    my $title   = shift || $linkref;

    # Convert any #<anchor> in the linkref
    $linkref =~ s/\#/-/g;
    $linkref = space_to_underscore($linkref);

    my $link = '[link to="AUTO-'.$linkref.'"]'.$title.'[/link]';

    $logger -> print($logger -> DEBUG, "Converted mediawiki link to $namespace:$linkref (title: $title) to '$link'");
    return $link;
}


## @fn $ make_anchor_name($module, $title)
# Generate a unique anchor for the specified module and, if specified, step title.
#
# @param module The name of the module.
# @param title  The optional name of the step title.
# @return A string containing the anchor name.
sub make_anchor_name {
    my $module = shift;
    my $title  = shift;

    my $basename = space_to_underscore($module);
    $basename .= "-".space_to_underscore($title) if($title);
    my $testname = $basename;

    # Keep appending an incrementing number until an unused anchor is encountered
    my $num = 2;
    while($anchorhash -> {$testname}) {
        $testname = $basename."_".$num;
        ++$num;
    }

    $anchorhash -> {$testname} = 1;
    return $testname;
}


## @fn $ fix_popup_wikitext($wikih, $page, $b64body, $mediahash)
# Fix the media and other links inside a popup.
#
# @param wikih   The wiki API handle to issue requests through if needed.
# @param page      The page on which this content appears.
# @param module    The name of the module to export, without namespace
# @param title     The current step title.
# @param b64body The base64-encoded popup body.
# @return A new popup inner block with fixed links and media.
sub fix_popup_wikitext {
    my $wikih     = shift;
    my $page      = shift;
    my $module    = shift;
    my $title     = shift;
    my $b64body   = shift;
    my $mediahash = shift;

    my $decoded = decode_base64($b64body);
    $logger -> print($logger -> DEBUG, "Processing popup.\nData: $b64body\nDeocded: $decoded\n") unless($quiet);

    return '<span class="twpopup-inner">'.encode_base64(fix_wikitext($wikih, $page, $module, $title, $decoded, $mediahash)).'</span>';
}


## @fn $ fix_header($level, $id, $text, $module, $title)
# Generate a header of the specified type, with a target anchor added.
#
# @param level  The header level (1, 2, etc)
# @param id     The id of the header
# @param text   The header text
# @param module The name of the module this occurs in.
# @param title  The current step title.
# @return A string containing the header
sub fix_header {
    my $level  = shift;
    my $id     = shift;
    my $text   = shift;
    my $module = shift;
    my $title  = shift;

    my $targ = '[target name="AUTO-'.make_anchor_name($module, $id)."\"]";

    $logger -> print($logger -> DEBUG, "Adding auto-target to $module/$title: $targ");

    return "<h$level><span id=\"$id\">$text</span></h$level>$targ";
}


## @fn $ fix_wikitext($wikih, $page, $module, $title, $content, $mediahash)
# Fix media and other links inside step content.
#
# @param wikih     The wiki API handle to issue requests through if needed.
# @param page      The page on which this content appears.
# @param module    The name of the module to export, without namespace
# @param title     The current step title.
# @param content   The content to fix.
# @param mediahash A reference to a hash of media files in the media directory.
# @return The text with links and media files corrected.
sub fix_wikitext {
    my $wikih     = shift;
    my $page      = shift;
    my $module    = shift;
    my $title     = shift;
    my $content   = shift;
    my $mediahash = shift;

    # First we need to deal with autogenerated content (ie: math tag output)
    $content =~ s{src="$wikih->{siteinfo}->{imagepath}/math(/.+?)"}{process_generated_media($wikih, "math", $1, $mediahash)}ges;

    # And any thumbnails
    $content =~ s{src="$wikih->{siteinfo}->{imagepath}/thumb(/.+?)"}{process_generated_media($wikih, "thumb", $1, $mediahash)}ges;

    # Fix up any local media links
    $content =~ s|"$wikih->{siteinfo}->{imagepath}/(?:[\w\.]+/)*([^"]+?)"|"../../$mediadir/$1"|gs;
    $content =~ s|'$wikih->{siteinfo}->{imagepath}/(?:[\w\.]+/)*([^"]+?)'|'../../$mediadir/$1'|gs;
    $content =~ s|"$wikih->{siteinfo}->{script}/File:(.*?)"|"../../$mediadir/$1"|gs;

    # Now check that the media link is actually valid.
    $content =~ s{"../../$mediadir/([^"]+?)"}{check_media_file($wikih, $1, $mediahash)}ges;
    $content =~ s{'../../$mediadir/([^"]+?)'}{check_media_file($wikih, $1, $mediahash)}ges;

    # Finally, we want to check for and fix completely broken file links
    $content =~ s{<a href=".*?\?title=Special:Upload&amp;wpDestFile=.*?" class="new" title="(File:[^"]+)">File:.*?</a>}{broken_media_link($1, $page)}ges;

    # Fix popups
    $content =~ s{<span class="twpopup-inner">(.*?)</span>}{fix_popup_wikitext($wikih, $page, $module, $title, $1, $mediahash)}ges;

    # Fix headers
    $content =~ s{<h(\d)><span class="editsection">\[<a.*?>edit</a>]</span> <span class="mw-headline" id="([^"]+)">(.*?)</span></h\d>}{fix_header($1, $2, $3, $module, $title)}ges;

    return $content;
}


## @fn $ process_entities_html($wikih, $page, $text)
# Process the entities in the specified text, allowing through only approved tags, and
# convert wiki markup to html.
#
# @note From v1.7 on this function does no recursively process transclusions, as all
#       transclusion processing has been moved into wiki_fetch.
#
# @param wikih     The wiki API handle to issue requests through if needed.
# @param page      The page on which this content appears.
# @param text      The text to process.
# @param mediahash A reference to a hash of media files in the media directory.
# @return The processed text.
sub process_entities_html {
    my $wikih     = shift;
    my $page      = shift;
    my $title     = shift;
    my $text      = shift;
    my $stepnum   = shift;
    my $mediahash = shift;

    # Fix up local links within the course
    $text =~ s{\[\[$namespace:([^\|\]]+?)(?:\|(.*?))?\]\]}{process_link($1,$2)}ges;

    my ($module) = $page =~ /^$namespace:(.*)$/;

    # work out a [target] unique to each step
    my $targ = '[target name="AUTO-'.make_anchor_name($module, $title)."\"]\n";
    $targ .= '[target name="AUTO-'.make_anchor_name($module)."\"]\n" if($stepnum == 1); # first step gets a special module marker

    $logger -> print($logger -> DEBUG, "Adding auto-targets to $page/$title:\n$targ");

    $text = $targ.$text;

    my $content = wiki_parsetext($wikih, $page, $text);
    my $result =  fix_wikitext($wikih, $page, $module, $title, $content, $mediahash);

    return $result;
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

    $logger -> print($logger -> NOTICE, "Extracting metadata xml from $title...") unless($quiet);

    # We have a page, can we pull the metadata out?
    my ($metadata) = $page =~ m|==\s*$config->{wiki2course}->{metadata}\s*==\s*<pre>\s*(.*?)\s*</pre>|ios;

    # Do we have metadata? If not, try again with <source> instead of <pre>
    # Yes, we could do this in one regexp above, but
    ($metadata) = $page =~ m|==\s*$config->{wiki2course}->{metadata}\s*==\s*<source.*?>\s*(.*?)\s*</source>|ios
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
                $logger -> print($logger -> WARNING, "name attribute for module $title contains spaces. This is not permitted.") unless($quiet);
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

    save_file(path_join($outdir, "metadata.xml"), "<?xml version='1.0' standalone='yes'?>\n".$metadata."\n");
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

    die "FATAL: Unable to locate course metadata in the course data page.\n"
        if(!$metadata);

    # We have metadata, so save it
    metadata_save($metadata, $destdir);
}


# -----------------------------------------------------------------------------
#  Module export

## @fn $ wiki_export_module($wikih, $themetitle, $module, $moduledir, $convert, $markers)
# Export the specified module to the module directory, splitting the steps into
# separate files inside the directory. This determines whether the module dir
# exists and, if it does not, it creates it, then it tries to save the module
# into it as separate steps.
#
# @param wikih      A reference to a MediaWiki API object.
# @param themetitle The title of the theme being exported
# @param module     The name of the module to export, including namespace
# @param moduledir  The directory to write the module data to.
# @param convert    If true, step contents are converted from wiki markup to html.
# @param markers    A reference to a hash to store marker information in.
# @param mediahash  A reference to a hash of media files in the media directory.
# @return true if the module was saved, false if there was a problem
sub wiki_export_module {
    my $wikih      = shift;
    my $themetitle = shift;
    my $module     = shift;
    my $moduledir  = shift;
    my $convert    = shift;
    my $markers    = shift;
    my $mediahash  = shift;

    $logger -> print($logger -> NOTICE, "Exporting module $module to $moduledir.") unless($quiet);

    # Sort out the directory
    if(makedir($moduledir, $logger)) {
        my $mpage = wiki_fetch($wikih, $module, 1);

        # Do we have any content? If not, bomb now
        if($mpage) {

            # Strip anything before the first title
            $mpage =~ s/^.*?==/==/s;

            # Mark the == title == a little more reliably
            $mpage =~ s/^==([^=].*?)==/--==$1==/gm;

            my @steps = split("--==", $mpage);

            if(scalar(@steps)) {
                my $stepnum = 0;

                foreach my $step (@steps) {
                    if($step) {
                        my ($title, $body) = $step =~ m{^\s*(.*?)\s*==\s*(.*)$}iso;

                        # If we have a title we need to write the text out as html
                        if($title) {
                            # If we have no body, write out a placeholder and tell the user
                            if(!$body) {
                                $logger -> print($logger -> WARNING, "Step '$title' in module '$module' has no body. Inserting placeholder message.");
                                $body = "This step has been intentionally left blank.";
                            }

                            my $stepname = path_join($moduledir, sprintf("step%02d.html", ++$stepnum));

                            if($convert) {
                                $logger -> print($logger -> NOTICE, "Converting mediawiki markup in $stepname to html.") unless($quiet);
                                $body = process_entities_html($wikih, $module, $title, $body, $stepnum, $mediahash);
                            }

                            save_file($stepname,
                                      "<html>\n<head>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"/>\n<title>".
                                      $title.
                                      "</title>\n</head><body><div id=\"content\">\n".
                                      $body.
                                      "\n</div><!-- id=\"content\" -->\n</body>\n</html>\n");

                            # Locate and record any markers
                            my @marklist = $body =~ /(.{0,16}\?\s*\?\s*\??.{0,56})/go;
                            $markers -> {"$themetitle; $module; $title ($stepname)"} = \@marklist
                                if(scalar(@marklist));

                        # Otherwise, work out where the problem was...
                        } else {
                            # kill newlines, otherwise it'll cause confusion in the output.
                            $step =~ s/\n/<br>/g;

                            if(!$title && $body) {
                                die "FATAL: Unable to parse title from '== $step' in module $module\n";
                            } else {
                                die "FATAL: Unable to parse body or title from $step in module $module\n";
                            }
                        }
                    }
                }
            } else { # if(scalar(@steps)) {
                die "FATAL: Unable to parse steps from content of $module.\n";
            }


        } else { # if($mpage) {
            $logger -> print($logger -> WARNING, "No content for $module.") unless($quiet);
        }
    } # if(makedir($moduledir, $logger)) {

    return 0;
}


## @fn $ wiki_export_modules($wikih, $themetitle, $themepage, $themedir, $metadata, $convert, $markers)
# Export the modules listed in the supplied theme page to the specified
# data directory.
#
# @param wikih      A reference to a MediaWiki API object.
# @param themetitle The human readable title of the theme being exported.
# @param themepage  The text of the theme page
# @param themedir   The base output directory.
# @param metadata   The theme metadata, needed for module dir naming.
# @param convert    If true, step contents are converted from wiki markup to html.
# @param markers    A reference to a hash to store marker information in.
# @param mediahash  A reference to a hash of media files in the media directory.
# @return The number of modules exported, or -1 on error.
sub wiki_export_modules {
    my $wikih      = shift;
    my $themetitle = shift;
    my $themepage  = shift;
    my $themedir   = shift;
    my $metadata   = shift;
    my $convert    = shift;
    my $markers    = shift;
    my $mediahash  = shift;

    $logger -> print($logger -> NOTICE, "Parsing module names from theme page...") unless($quiet);

    # parse out the list of modules first
    my ($names) = $themepage =~ m|==\s*$config->{wiki2course}->{modules_title}\s*==\s*(.*?)\s*==|ios;

    # Die if we have no modules
    if(!$names) {
        die "FATAL: Unable to parse $config->{wiki2course}->{modules_title} names from theme page. Check that you have a == $config->{wiki2course}->{modules_title} == title on the page.\n";
        return -1;
    }

    # Split the names up
    my @modules = $names =~ m{^\s*\[\[(.*?)(?:\|.*?)?\]\]}gim;

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
                wiki_export_module($wikih, $themetitle, $module, $modulepath, $convert, $markers, $mediahash);

            } else {
                die "FATAL: Unable to locate metadata entry for $truename. (Remember, the module name without namespace MUST match the metadata title!)\n";
            }
        } else {
            die "FATAL: Unable to remove namespace from $module.\n";
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
# @param wikih     A reference to a MediaWiki API object.
# @param theme     The name of the theme to export, including namespace
# @param basedir   The base output directory.
# @param convert   If true, step contents are converted from wiki markup to html.
# @param markers   A reference to a hash to store marker information in.
# @param mediahash A reference to a hash of media files in the media directory.
# @return true if the theme was exported successfully, false otherwise
sub wiki_export_theme {
    my $wikih     = shift;
    my $theme     = shift;
    my $basedir   = shift;
    my $convert   = shift;
    my $markers   = shift;
    my $mediahash = shift;

    $logger -> print($logger -> NOTICE, "Fetching page data for $theme...") unless($quiet);

    # Okay, does the theme page exist?
    my $tpage = wiki_fetch($wikih, $theme, 1);

    # Do we have any content? If not, bomb now
    if(!$tpage) {
        $logger -> print($logger -> WARNING, "No content for $theme.") unless($quiet);
        return 0;
    }

    # Attempt to obtain the metadata for the theme, if we can't then This is Not Good - we need that
    # information to do, well, anything.
    my $metadata = metadata_find($tpage, $theme);
    if(!$metadata) {
        die "FATAL: Unable to parse metadata from $theme. Unable to process theme.\n";
        return 0;
    }

    $logger -> print($logger -> NOTICE, "Parsing metadata information to determine directory structure...") unless($quiet);

    # Parse the metadata into a useful format
    my $mdxml;
    eval { $mdxml = XMLin($metadata, ForceArray => ['module'] ); };

    # Fall over if we have an error.
    die "FATAL: Unable to parse metadata for $theme. Error was:\n$@\n" if($@);

    # Did the parse work?
    if($mdxml) {

        # Do we have the required fields (name, really, at this point)
        if($mdxml -> {"name"}) {

            # The name Must Not Contain Spaces or we're full of woe and pain
            if($mdxml -> {"name"} !~ /\s/) {

                # Okay, we have something we can work with - create the theme directory
                my $themedir = path_join($basedir, $mdxml -> {"name"});

                $logger -> print($logger -> NOTICE, "Creating theme directory ",$mdxml -> {"name"}," for $theme...") unless($quiet);
                if(makedir($themedir, $logger)) {

                    # We have the theme directory, now we need to start on modules!
                    wiki_export_modules($wikih, $mdxml -> {"title"}, $tpage, $themedir, $mdxml, $convert, $markers, $mediahash);

                    # Modules are processed, try saving the metadata
                    metadata_save($metadata, $themedir);

                    return 1;
                }
            } else { # if($mdxml -> {"name"} !~ /\s/) {
                die "FATAL: name element for $theme contains spaces. This is not permitted.\n";
            }
        } else { # if(!$mdxml -> {"name"}) {
            die "FATAL: metadata element does not have a name attribute. Unable to save theme.\n";
        }
    } else { # if($mdxml) {
        die "FATAL: Unable to parse metadata. Check the metadata format and try again.\n";
    }

    return 0;
}


## @fn $ wiki_export_themes($wikih, $cdpage, $basedir, $convert, $markers)
# Export the themes listed in the supplied coursedata page to the specified
# data directory.
#
# @param wikih     A reference to a MediaWiki API object.
# @param cdpage    The text of the coursedata page
# @param basedir   The base output directory.
# @param convert   If true, step contents are converted from wiki markup to html.
# @param markers   A reference to a hash to store marker information in.
# @param mediahash A reference to a hash of media files in the media directory.
# @return  The number of themes exported, or -1 on error.
sub wiki_export_themes {
    my $wikih     = shift;
    my $cdpage    = shift;
    my $basedir   = shift;
    my $convert   = shift;
    my $markers   = shift;
    my $mediahash = shift;

    $logger -> print($logger -> NOTICE, "Parsing theme names from course data page...") unless($quiet);

    # parse out the list of themes first
    my ($names) = $cdpage =~ m|==\s*$config->{wiki2course}->{themes_title}\s*==\s*(.*?)\s*==|ios;

    # Die if we have no themes
    if(!$names) {
        die "FATAL: Unable to parse theme names from course data page.\n";
        return -1;
    }

    # Split the names up
    my @themes = $names =~ m{^\s*\[\[(.*?)(?:\|.*?)?\]\]}gim;

    my $count = 0;
    # Process each theme
    foreach my $theme (@themes) {
        ++$count if(wiki_export_theme($wikih, $theme, $basedir, $convert, $markers, $mediahash));
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
# @return A reference to a hash of filenames of files downloaded. The hash keys
#         will be the lower-case filenames, while the values contain the actual
#         name without any case modifications.
sub wiki_export_files {
    my $wikih      = shift;
    my $listpage   = shift;
    my $destdir    = shift;

    my $filenames; # Store a hash of filenames saved into the media dir here...

    # We need the page to start with
    my $list = wiki_fetch($wikih, $listpage, 1);

    # Do we have any content? If not, bomb now
    if(!$list) {
        $logger -> print($logger -> WARNING, "No content for $listpage.") unless($quiet);
        return 0;
    }

    if(makedir($destdir, $logger)) {
        # Now we can do a quick and dirty yoink on the file/image links
        my @entries = $list =~ m{\[\[((?:Image:|File:)[^|\]]+)}goi;

        if(scalar(@entries)) {
            $logger -> print($logger -> NOTICE, "$listpage shows ".scalar(@entries)." files to download. Processing...") unless($quiet);

            my $writecount = 0;
            my $file;
            foreach my $entry (@entries) {
                # First, we need to remove spaces
                $entry =~ s/ /_/g;

                # Work out the filename
                my ($name) = $entry =~ /^(?:Image|File):(.*)$/io;

                if($name) {
                    my $filename = path_join($destdir, $name);

                    $logger -> print($logger -> NOTICE, "Downloading '$entry'") unless($quiet);

                    my $errs = wiki_download($wikih, $name, $filename);
                    if($errs) {
                        $logger -> print($logger -> WARNING, "Unable to download '$name': $errs") unless($quiet);
                    } else {
                        if(-z $filename) {
                            $logger -> print($logger -> WARNING, "Zero length file written for $filename! This file will be ignored.") unless($quiet);
                        } else {
                            ++$writecount;
                            $filenames -> {lc($name)} = $name;
                        }
                    }
                } else {
                    die "FATAL: Unable to determine filename from $entry.\n";
                }
            }

            $logger -> print($logger -> NOTICE, "Wrote $writecount files.") unless($quiet);

            return $filenames;
        } else {
            $logger -> print($logger -> NOTICE, "No files or images listed on $listpage. Nothing to do here.") unless($quiet);
        }
    } else {
        die "FATAL: Unable to create directory $destdir: $@\n";
    }

    return undef;
}


# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

# Process the command line
GetOptions('outputdir|o=s' => \$basedir,
           'username|u=s'  => \$username,
           'password|p=s'  => \$password,
           'mediadir|m=s'  => \$mediadir,
           'namespace|n=s' => \$namespace,
           'fileurl|f=s'   => \$fileurl,
           'wiki|w=s'      => \$apiurl,
           'convert|c=s'   => \$convert,
           'config|g=s'    => \$configfile,
           'pid=s'         => \$pidfile,
           'verbose|v+'    => \$verbose,
           'quiet|q!'      => \$quiet,
           'retainold|r!'  => \$retainold,
           'help|?|h'      => \$help,
           'man'           => \$man) or pod2usage(2);
if(!$help && !$man) {
    print STDERR "No username specified.\n" if(!$username);
    print STDERR "No output directory specified.\n" if(!$basedir);
}
pod2usage(-verbose => 2) if($man);
pod2usage(-verbose => 0) if($help || !$username);

# Before doing any real work, write the PID if needed.
write_pid($pidfile) if($pidfile);

print "wiki2course.pl version ",get_version("wiki2course")," started.\n" unless($quiet);

# set up the logger and configuration data
$logger -> set_verbosity($verbose);
$config = load_config($configfile, $default_config, "wiki2course", $logger);

# Override the api and wiki if set on the command like
$config -> {"wiki2course"} -> {"api_url"}  = $apiurl if($apiurl);
$config -> {"wiki2course"} -> {"wiki_url"} = $fileurl if($fileurl);

die "FATAL: No wiki API URL has been specified either on the command line or in your configuration file. Unable to continue.\n"
    unless($config -> {"wiki2course"} -> {"api_url"});

die "FATAL: No wiki URL has been specified either on the command line or in your configuration file. Unable to continue.\n"
    unless($config -> {"wiki2course"} -> {"wiki_url"});

# Locate necessary binaries
find_bins($config);

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

# Remove any old coursedata directory, unless it doesn't exist or we don't need to
if(-e $basedir && !$retainold) {
    $logger -> print($logger -> DEBUG, "Removing old output directory.") unless($quiet);
    `$config->{paths}->{rm} -rf $basedir`;
}

# Now we need to process the output directory. Does it exist?
if(makedir($basedir, $logger)) {
    # Get the show on the road...
    my $wikih = MediaWiki::API -> new({api_url => $config -> {"wiki2course"} -> {"api_url"} });

    # Set the file url
    $wikih -> {"config"} -> {"files_url"} = $config -> {"wiki2course"} -> {"wiki_url"};

    # Now we need to get logged in so we can get anywhere
    wiki_login($wikih, $username, $password);

    # Check the specified namespace is valid
    die "FATAL: The specified namespace does not appear in the wiki. Can't export from a namespace that doesn't exist!\n"
        unless(wiki_valid_namespace($wikih, $namespace));

    # Get the coursedata page
    my $cdpage = wiki_course_exists($wikih, $namespace, $config);

    # Bomb if we don't have a hashref
    die $cdpage if(!ref($cdpage));

    # Write out images and animations so that we have a list of valid media
    my $mediahash = wiki_export_files($wikih, "$namespace:$config->{wiki2course}->{media_page}", path_join($basedir, $mediadir));

    # Pull down the text data
    wiki_export_themes($wikih, $cdpage -> {"*"}, $basedir, $convert, $markers, $mediahash);

    # save course metadata
    course_metadata_save($cdpage -> {"*"}, $basedir);

    # Print out any markers
    if(!$quiet) {
        foreach my $step (sort keys(%$markers)) {
            $logger -> print($logger -> NOTICE, "Found the following markers in $step:");
            foreach my $marker (@{$markers -> {$step}}) {
                print "    ...$marker...\n";
            }
            print "\n";
        }
    }
}

print "Export finished.\n";


# THE END!
__END__

=head1 NAME

wiki2course - generate a course data directory from a wiki namespace.

=head1 SYNOPSIS

wiki2course [options]

 Options:
    -c, --convert=MODE       convert mediawiki markup to html (default: on)
    -f, --fileurl=URL        the location of the wiki.
    -g, --config=FILE        Use an alternative configuration file.
    -h, -?, --help           brief help message.
    --man                    full documentation.
    -m, --mediadir=DIR       the subdir into which media should be written.
    -n, --namespace=NAME     the namespace containing the course to export.
    -o, --outputdir=DIR      the name of the directory to write to.
    -p, --password=PASSWORD  password to provide when logging in. If this is
                             not provided, it will be requested at runtime.
    --pid=FILE               write the process id to a file.
    -q, --quiet              suppress all normal status output.
    -r, --retainold          do not delete the output directory if it exists.
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

=item B<-f, --config>

Specify an alternative configuration file to use during exporting. If not set,
the .courseprocessor.cfg file in the user's home directory will be used instead.

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

=item B<-r, --retainold>

Normally the wiki2course script will remove the output directory if it already
exists. If you want to suppress this operation for some reason, include this
flag.

=item B<-u, --username>

I<This argument must be provided.> This argument specifies which username
should be used to log into the wiki. This must correspond to a valid wiki
user, and you will need to either provide the password using the --password
option described above, or you will be prompted to enter the password by
wiki2course.pl. If your username contains spaces, please ensure that you
either enclose the username in quotes, or replace any spaces with
underscores. Note that wiki usernames B<are case sensitive>, so check that
you use the correct case when specifying your username or the login will fail.

=item B<-v, --verbose>

Increase the verbosity of status reporting. By default (unless the quiet flag
is set), wiki2course.pl will only output warning messages during course export.
If you include -v on the command line, it will output warnings and notices.
For complete status information including debug messages, specify -v twice
(-v -v).

=item B<-w, --wiki>
This argument is optional. If provided, the script will use the MediaWiki API
script specified rather than the default DevWiki version.

=back

=head1 DESCRIPTION

=over 8

Please consult the Docs:wiki2course.pl documentation in the wiki for a full
description of this program.

=back

=cut

