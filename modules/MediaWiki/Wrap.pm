
# @file MediaWiki.pm
# MediaWiki interaction functions, for the wiki2course and course2wiki
# scripts.
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0

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

package MediaWiki::Wrap;
use Exporter;
use MediaWiki::API;
use URI::Encode qw(uri_encode);

our @ISA       = qw(Exporter);
our @EXPORT    = qw(wiki_login wiki_parsetext wiki_transclude wiki_fetch wiki_course_exists wiki_download wiki_download_direct wiki_media_url wiki_media_size wiki_valid_namespace wiki_link wiki_edit_page wiki_upload_media space_to_underscore);
our @EXPORT_OK = qw();
our $VERSION   = 1.0;

#use Data::Dumper;
use Utils qw(path_join);

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
        or die "FATAL: Unable to log into the wiki. Error from the API was:".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";


    # While we are here, get hold of useful information about the server...
    my $response = $wikih -> api({ action => 'query',
                                   meta   => 'siteinfo'} )
        or die "FATAL: Unable to obtain site information. Error from the API was:".$wikih->{"error"}->{"code"}.': '.$wikih->{"error"}->{"details"}."\n";

    # store the site info we're interested in...
    $wikih -> {"siteinfo"} = $response -> {"query"} -> {"general"};

    # Precalculate the images location as we'll need that anyway, assumes the default upload path
    $wikih -> {"siteinfo"} -> {"imagepath"} = path_join($wikih -> {"siteinfo"} -> {"scriptpath"}, "images");

    # And the generated media path
    $wikih -> {"siteinfo"} -> {"mathpath"}  = path_join($wikih -> {"siteinfo"} -> {"imagepath"}, "math");
    $wikih -> {"siteinfo"} -> {"thumbpath"} = path_join($wikih -> {"siteinfo"} -> {"imagepath"}, "thumb");

#    die Data::Dumper -> Dump([$wikih -> {"siteinfo"}]);

    return 1;
}


## @fn $ wiki_parsetext($wikih, $pagename, $contentstr)
# Call the mediawiki API to convert the specified content to html. This should
# result in the wiki spitting out the processed content as it appears in the
# wiki itself.
sub wiki_parsetext {
    my $wikih      = shift;
    my $pagename   = shift;
    my $contentstr = shift;

    # Append the <references/> if any <ref>s occur in the text, and no <references> does
    # This ensures that we always have an anchor for refs
    $contentstr .= "\n<references/>\n"
        if($contentstr =~ /<ref>/ && $contentstr !~ /<references\/>/);

    my $response = $wikih -> api({ action => 'parse',
                                   title  => $pagename,
                                   text   => $contentstr} )
        or die "FATAL: Unable to process content in page $pagename. Error from the API was:".$wikih->{"error"}->{"code"}.': '.$wikih->{"error"}->{"details"}."\n";

    # Fall over if the query returned nothing.
    die "FATAL: Unable to obtain any content when parsing page $pagename\n" if(!$response -> {"parse"} -> {"text"} -> {"*"});

    return $response -> {"parse"} -> {"text"} -> {"*"};
}


## @fn $ wiki_transclude($wikih, $page, $templatestr)
# Call on the mediawiki api to convert the specified template string, doing any
# transclusion necessary.
#
# @param wikih       A reference to a MediaWiki API object.
# @param pagename    The title of the page the transclusion appears on
# @param templatestr The unescaped transclusion string, including the {{ }}
sub wiki_transclude {
    my $wikih       = shift;
    my $pagename    = shift;
    my $templatestr = shift;

    my $response = $wikih -> api({ action => 'expandtemplates',
                                   title  => $pagename,
                                   prop   => 'revisions',
                                   text   => $templatestr} )
        or die "FATAL: Unable to process transclusion in page $pagename. Error from the API was:".$wikih->{"error"}->{"code"}.': '.$wikih->{"error"}->{"details"}."\n";

    # Fall over if the query returned nothing. This probably shouldn't happen - the only situation I can
    # think of is when the target of the transclusion is itself empty, and we Don't Want That anyway.
    die "FATAL: Unable to obtain any content for transclusion in page $pagename" if(!$response -> {"expandtemplates"} -> {"*"});

    return $response -> {"expandtemplates"} -> {"*"};
}


## @fn $ wiki_fetch($wikih, $pagename, $transclude)
# Attempt to obtain the contents of the specified wiki page, optionally doing
# page transclusion on the content.
#
# @param wikih      A reference to a MediaWiki API object.
# @param pagename   The title of the page to fetch.
# @param transclude Enable transclusion of fetched pages.
# @return A string containing the page data.
sub wiki_fetch {
    my $wikih      = shift;
    my $pagename   = shift;
    my $transclude = shift;

    # First attempt to get the page
    my $page = $wikih -> get_page({ title => $pagename } )
        or die "FATAL: Unable to fetch page '$pagename'. Error from the API was: ".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Do we have any content? If not, return an error...
    die "FATAL: $pagename page is missing!\n" if($page -> {"missing"});

    my $content = $page -> {"*"};

    # Return right here if we are not transcluding, no point doing more work than we need.
    return $content if(!$transclude || !$content);

    # Strip any coursenav transclusions
    $content =~ s|<noinclude>{{.*?:CourseNav}}</noinclude>||gis;

    # Break any transclusions inside <nowiki></nowiki>
    while($content =~ s|(<nowiki>.*?)\{\{([^<]+?)\}\}(.*?</nowiki>)|$1\{\(\{$2\}\)\}$3|is) { };

    # recursively process any remaining transclusions
    $content =~ s/(\{\{.*?\}\})/wiki_transclude($wikih, $pagename, $1)/ges;

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
    my $config = shift;

    # First, get the course page
    my $course = $wikih -> get_page({ title => "$nspace:$config->{wiki2course}->{course_page}" } )
        or die "FATAL: Unable to fetch $nspace:Course page. Error from the API was:".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Is the course page present?
    die "FATAL: $nspace:$config->{wiki2course}->{course_page} page is missing!\n" if(!$course -> {"*"});

    # Do we have a coursedata link in the page?
    my ($cdlink) = $course -> {"*"} =~ /\[\[($nspace:$config->{wiki2course}->{data_page})\|.*?\]\]/i;

    # Bomb if we have no coursedata link
    die "FATAL: $nspace:$config->{wiki2course}->{course_page} page does not contain a $config->{wiki2course}->{data_page} link.\n"
        if(!$cdlink);

    # Fetch the linked page
    my $coursedata = $wikih -> get_page({ title => $cdlink })
        or die "FATAL: Unable to fetch $config->{wiki2course}->{data_page} page ($cdlink). Error from the API was:".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"}."\n";

    # Do we have any content? If not, return an error...
    die "FATAL: $cdlink page is missing!\n" if($coursedata -> {"missing"});
    die "FATAL: $cdlink page is empty!\n" if(!$coursedata -> {"*"});

    # Get here and we have a coursedata page with some content, return the full thing
    my $content = wiki_fetch($wikih, $cdlink, 1);

    return {"*" => $content} if($content);

    die "FATAL: No content for $cdlink. Unable to process course.\n";
}


## @fn $ wiki_download($wikih, $title, $filename)
# Attempt to download the file identified by the title from the wiki, and save it
# to the specified title.
#
# @param wikih    A reference to the mediawiki API object.
# @param title    The title of the file to download. Any namespace will be stripped!
# @param filename The name of the file to write the contents to.
# @return undef on success, otherwise an error message.
sub wiki_download {
    my $wikih    = shift;
    my $title    = shift;
    my $filename = shift;

    # Work out where the image is...
    my $url = wiki_media_url($wikih, $title);
    return "Unable to obtain url for '$title'. This file does not exist in the wiki!" if(!$url);

    # And download it
    return wiki_download_direct($wikih, $url, $filename);
}


## @fn $ wiki_download_direct($wikih, $url, $filename)
# Download a file directly from the wiki, bypassing the normal API. This is generally
# needed to obtain thumbnails or generated images (for example, .png files written by
# the math tag). While this does take a reference to the api object, it doesn't use
# it, rather we borrow the LWP::UserAgent object it has within it...
#
# @param wikih    A reference to the mediawiki API object.
# @param url      The URL of the file to download. If this is relative, attempts are made
#                 to make it an absolute URL.
# @param filename The name of the file to save the download to.
# @return undef on success, otherwise an error message (serious errors are fatal within
#         the function)
sub wiki_download_direct {
    my $wikih    = shift;
    my $url      = shift;
    my $filename = shift;

    # First, if the url does not start with https?, we need to prepend the server
    if($url !~ m|^https?://|i) {
        # We can't do a thing about dotted relative paths
        die "FATAL: Unable to process relative path in direct download request" if($url =~ /^\.\./);

        my ($server) = $wikih -> {"config"} -> {"api_url"} =~ m|^(https?://[^/]+)|i;
        die "FATAL: Unable to obtain server from api url.\n" if(!$server);

        $url = path_join($server, $url);
    }

    my $response = $wikih -> {"ua"} -> get($url, ":content_file" => $filename);

    return "Unable to download $url. Response was: ".$response -> status_line()
        if(!$response -> is_success());

    return undef;
}


## @fn $ wiki_media_url($wikih, $title)
# Attempt to obtain the URL of the media file with the given title. This will assume
# the media file can be accessed via the Image: namespace, and any namespace given
# will be stripped before making the query
#
# @param wikih A reference to a MediaWiki API object.
# @param title The title of the media file to obtain the URL for
# @return The URL to the media file, or undef if it can not be located.
sub wiki_media_url {
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
            die "FATAL: The API returned a relative path for the URL for '$title'. You must provide a value for the fileurl argument and try again.\n";
        }
        $url = $wikih -> {"config"} -> {"files_url"}.$url;
    }

    return $url;
}


## @fn @ wiki_media_size($wikih, $title)
# Attempt to obtain the width and height of the media file with the given title.
# This will assume the media file can be accessed via the Image: namespace, and
# any namespace given will be stripped before making the query
#
# @param wikih A reference to a MediaWiki API object.
# @param title The title of the media file to obtain the URL for
# @return The width and height of the media, or undef if they can not be obtained.
sub wiki_media_size {
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


## @fn $ wiki_valid_namespace($wikih, $namespace, $minid, $maxid)
# Determine whether the specified namespace exists in the wiki. This will return
# true if the namespace exists, false if it does not.
#
# @param wikih A reference to a MediaWiki API object.
# @param namespace The namespace to look for in the wiki.
# @param minid Optional lower limit on the namespace id, inclusive. Defaults to 100.
# @param maxid Optional upper limit on the namespace id, inclusive. Defaults to 998.
# @return true if the namespace exists, false otherwise.
sub wiki_valid_namespace
{
    my $wikih     = shift;
    my $namespace = shift;
    my $minid     = shift;
    my $maxnid    = shift;

    # Set defaults as needed
    $minid = 100 if(!defined($minid));
    $maxid = 998 if(!defined($maxid));

    my $namespaces = $wikih -> api({ action => 'query',
                                     meta   => 'siteinfo',
                                     siprop => 'namespaces' })
        or die "FATAL: Unable to obtain namespace list from wiki. API error was: ".$mw -> {"error"} -> {"code"}.": ".$mw -> {"error"} -> {"details"}."\n";

    if($namespaces -> {"query"} -> {"namespaces"}) {
        foreach my $id (keys(%{$namespaces -> {"query"} -> {"namespaces"}})) {
            return 1 if($namespaces -> {"query"} -> {"namespaces"} -> {$id} -> {"*"} && # Must have a name
                        $namespaces -> {"query"} -> {"namespaces"} -> {$id} -> {"*"} eq $namespace && # Must match the requested name
                        $id >= $minid && # id must be 100 or more unless overridden
                        $id <= $maxid && # id must be 998 or less unless overridden
                        $id % 2 == 0);   # id must be even (ie: not a Talk namespace)
        }
    }

    return 0;
}


## @fn $ wiki_link($title, $name)
# Generate a wiki link for the specified title. This is a simple convenience
# function to wrap the specified title in the brackets needed to make
# it into a link. If the specified title is '' or undef, this returns ''.
#
# @param title The title to convert to a wiki link.
# @param name  An optional name to use instead of the title.
# @return The link to the page with the specified title.
sub wiki_link {
    my $title = shift;
    my $name  = shift;

    return $title ? '[['.$title.($name ? "|$name" : "").']]' : '';
}


## @fn void wiki_edit_page($wikih, $namespace, $title, $content, $dryrun)
# Edit (or create) a page in the wiki via the specified wiki handle. This will
# not care about conflicts, missing pages, or any 'niceties' - it sets the
# page content, not caring about any existing content.
#
# @param wikih     A reference to a MediaWiki API object.
# @param namespace The namespace the page should be created in.
# @param title     The title of the page to create/edit.
# @param content   A reference to the content to set in the page.
# @param dryrun    If set, the wiki is not updated and a message describing what
#                  would be done is printed instead.
sub wiki_edit_page {
    my $wikih     = shift;
    my $namespace = shift;
    my $title     = shift;
    my $content   = shift;
    my $dryrun    = shift;

    # If we have dry-run mode on, print out the page instead of uploading it
    if($dryrun) {
        print "Dry-run mode enabled. Wiki action that would be taken:\n";
        print "{ action => 'edit', title => '$namespace:$title', bot => 1}\n";
        print "Text will contain:\n$$content\n";
    } else {
        $wikih -> edit({ action => 'edit',
                         title  => "$namespace:$title",
                         text   => $$content,
                         bot    => 1})
            or die "FATAL: Unable to set content for page '$namespace:$title': ".$wikih -> {"error"} -> {"code"}.' - '.$wikih -> {"error"}->{"details"}."\n";
    }
}


## @fn $ wiki_upload_media($wikih, $file, $name, $dryrun)
# Upload the file at the specified location and give it the provided name.
#
# @param wikih  A reference to a MediaWiki API object.
# @param file   The path to the file to upload.
# @param name   The name of the file in the wiki.
# @param dryrun If true, the file is not really uploaded.
# @return undef on success, otherwise an error message.
sub wiki_upload_media {
    my $wikih  = shift;
    my $file   = shift;
    my $name   = shift;
    my $dryrun = shift;

    # If we have dry-run mode on, print out the page instead of uploading it
    if($dryrun) {
        print "Dry-run mode enabled. The following file would be uploaded to the wiki:\n";
        print " Source file: $file\nName in wiki: $name\n";

        # Make damned sure we can read it.
        open(RESFILE, $file)
            or return "Upload will fail as '$file' can not be opened: $!";
        close(RESFILE);

    } else {
        open(RESFILE, $file)
            or return "Failed to open media file '$file': $!";

        binmode RESFILE;
        my ($buffer, $data);
        while(read(RESFILE, $buffer, 65536))  {
            $data .= $buffer;
        }
        close(RESFILE);

        $wikih -> upload({ title => $name,
                           summary => 'File uploaded by bot',
                           data => $data })
            or return "Upload of $name failed: ".$wikih -> {"error"} -> {"code"}.': '.$wikih -> {"error"} -> {"details"};
    }
    return undef;
}


## @fn $ space_to_underscore($text)
# Convert any spaces in the specified text to underscores.
#
# @param text The text to convert.
# @return The converted text.
sub space_to_underscore {
    my $text = shift;

    $text =~ s/ /_/g;
    $text = uri_encode($text, 1);

    # colons are actually allowed
    $text =~ s/%3A/:/gi;

    # Mediawiki uses . rather than % for escaped
    $text =~ s/%/./g;

    return $text;
}

1;
