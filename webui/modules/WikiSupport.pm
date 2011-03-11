## @file
# This file contains the implementation of a wiki support class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 0.1
# @date    1 Mar 2011
# @copy    2011, Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# The WikiSupport class provides various functions specifically
# required by the course processor web ui.
package WikiSupport;

require 5.005;
use strict;

use MediaWiki::API;
use Utils qw(path_join);

# Globals...
use vars qw{$VERSION $errstr};

BEGIN {
	$VERSION = 0.1;
	$errstr  = '';
}

# ============================================================================
#  Constructor

## @cmethod WikiSupport new(@args)
# Create a new WikiSupport object, and start session handling.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new WikiSupport object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $obj     = {
        cgi          => undef,
        dbh          => undef,
        settings     => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($obj -> {"cgi"});
    return set_error("dbh object not set") unless($obj -> {"dbh"});
    return set_error("settings object not set") unless($obj -> {"settings"});

    return bless $obj, $class;
}


# =============================================================================
#  Metadata helpers

## @fn $ metadata_find($wikiconfig, $page)
# Attempt to extract the contents of a metadata block from the specified page.
# This will search for the == Metadata == marker in the specified page content, and
# attempt to extract any metadata enclosed in <pre> or <source> tags within the 
# section following the marker.
#
# @param wikiconfig A reference to the wiki's configuration object.
# @param page       The content of the page to extract metadata from.
# @return undef if no metadata is found, otherwise the metadata XML.
sub metadata_find {
    my $wikiconfig = shift;
    my $page  = shift;

    # We have a page, can we pull the metadata out?
    my ($metadata) = $page =~ m|==\s*$wikiconfig->{wiki2course}->{metadata}\s*==\s*<pre>\s*(.*?)\s*</pre>|ios;
    
    # Do we have metadata? If not, try again with <source> instead of <pre>
    # Yes, we could do this in one regexp above, but
    ($metadata) = $page =~ m|==\s*$wikiconfig->{wiki2course}->{metadata}\s*==\s*<source.*?>\s*(.*?)\s*</source>|ios
        if(!$metadata);

    # return whatever we may have now...
    return $metadata;
}


## @fn void metadata_filters($metadata, $filterhash)
# Look at the contents of the specified metadata, and put any filter names
# found in it into the provided hash.
#
# @param metadata   A string containing the metadata to check through.
# @param filterhash A reference to a hash to store filter names.
sub metadata_filters {
    my $metadata   = shift;
    my $filterhash = shift;
    
    # Do nothing if we have no metadata to wrangle
    return if(!$metadata);

    # check the metadata for possible filter elements elements...
    my @include_elems = $metadata =~ m|<include>(.*?)</include>|gs;
    my @exclude_elems = $metadata =~ m|<exclude>(.*?)</exclude>|gs;
    my @attribs       = $metadata =~ /(?:in|ex)clude="(.*?)"/gs;

    # push any include filter names into the hash
    foreach my $name (@include_elems) {
        $filterhash -> {$name} = 1;
    }

    # And the same for the excludes...
    foreach my $name (@exclude_elems) {
        $filterhash -> {$name} = 1;
    }

    # The attributes might be a bit more of a pain...
    foreach my $attrib (@attribs) {
        # each attrib can contain a comma-separated list of filters, so split it
        my @splitattribs = split(/,/, $attrib);

        # And go through the resulting array
        foreach my $name (@splitattribs) {
            $filterhash -> {$name} = 1;
        }
    }
}


# =============================================================================
#  Wiki interaction

## @fn $ check_wiki_login($username, $password, $wikiconfig)
# Check whether the specified user credentials correspond to a valid login
# for the selected wiki. This will attempt to log into the wiki using the
# username and password provided and, if the login is successful, return true.
# If the login fail for any reason, this will return false.
#
# @param username   The username to log into the wiki using.
# @param password   The password to provide when logging into the wiki.
# @param wikiconfig The configuration data corresponding to the wiki to log into.
# @return true if the user details allow them to log into the wiki, false if
# the user's details do not work (wrong username/password/no account/etc)
sub check_wiki_login {
    my $self       = shift;
    my $username   = shift;
    my $password   = shift;
    my $wikiconfig = shift;

    my $mw = MediaWiki::API -> new({ api_url => $wikiconfig -> {"WebUI"} -> {"api_url"} })
        or die "FATAL: Unable to create new MediaWiki API object.";

    my $status = $mw -> login( { lgname => $username, lgpassword => $password });

    # If we have a login, log out again and return true.
    if($status) {
        $mw -> logout();
        return 1;
    }

    # No login, give up
    return 0;
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

    # Do we have any content? If not, return nothing
    return "" if($page -> {"missing"});

    my $content = $page -> {"*"};

    # Return right here if we are not transcluding, no point doing more work than we need.
    return $content if(!$transclude || !$content);

    # Break any transclusions inside <nowiki></nowiki>
    while($content =~ s|(<nowiki>.*?)\{\{([^<]+?)\}\}(.*?</nowiki>)|$1\{\(\{$2\}\)\}$3|is) { };

    # recursively process any remaining transclusions
    $content =~ s/(\{\{.*?\}\})/wiki_transclude($wikih, $pagename, $1)/ges; 

    # revert the breakage we did above
    while($content =~ s|(<nowiki>.*?)\{\(\{([^<]+?)\}\)\}(.*?</nowiki>)|$1\{\{$2\}\}$3|is) { };

    # We should be able to return the page now
    return $content;
}


## @fn $ get_course_filters($wikiconfig, $course)
# Attempt to build up a list of all the filters available in the specified 
# course. This will check through the metadata for the specified course 
# looking for <filters> elements and records any filter names it encounters.
#
# @note This function will ignore any structuring problems with the wiki,
#       and even mask broken metadata errors - if it can't find or parse
#       metadta, it simply carries on without stopping.
#
# @param wikiconfig A reference to the wiki's configuration object.
# @param course     The name of the course namespace to check through.
# @return A string containing a comma-separated list of filter names.
sub get_course_filters {
    my $self       = shift;
    my $wikiconfig = shift;
    my $course     = shift;
    my $filterhash; # A hash to act as a set of filter names.

    my $mw = MediaWiki::API -> new({ api_url => $wikiconfig -> {"WebUI"} -> {"api_url"} })
        or die "FATAL: Unable to create new MediaWiki API object.";

    # Log in using the 'internal' export user.
    $mw -> login( { lgname     => $wikiconfig -> {"WebUI"} -> {"username"}, 
                    lgpassword => $wikiconfig -> {"WebUI"} -> {"password"}})
        or die "FATAL: Unable to log into wiki. This is possibly a serious configuration error.\nAPI reported: ".$mw -> {"error"} -> {"code"}.': '. $mw -> {"error"} -> {"details"};

    # now get the course 'Course' page, whatever it is called
    my $coursepage = wiki_fetch($mw, $course.":".$wikiconfig -> {"wiki2course"} -> {"course_page"}, 1);
    
    # if we have no content, give up now
    return "" unless($coursepage);

    # Try to pull the 'coursedata' page out
    my ($cdlink) = $coursepage =~ /\[\[($course:$config->{wiki2course}->{data_page})\|.*?\]\]/i;

    # If we have no coursedata, give up here
    return "" unless($cdlink);

    # Fetch the appropriate coursedata page
    my $coursedata = wiki_fetch($mw, $cdlink, 1);

    # pull any filters out of the metadata...
    metadata_filters(metadata_find($wikiconfig, $coursedata), $filterhash);

    # Now we need a list of theme names
    my ($names) = $cdpage =~ m|==\s*$config->{wiki2course}->{themes_title}\s*==\s*(.*?)\s*==|ios;

    # return any filters we have so far if we have no theme names
    return join(',', keys(%{$filterhash})) if(!$names);

    # We have names, so split them so we can pull theme pages
    my @themes = $names =~ m{^\s*\[\[(.*?)(?:\|.*?)?\]\]}gim;
    
    # Process each of the theme pages, pulling the metadata for each
    foreach my $theme (@themes) {
        my $page = wiki_fetch($mw, $theme, 1);

        # Do nothing if we have no page content
        next if(!$page);

        # Get the filter names out of the metadata
        metadata_filters(metadata_find($wikiconfig, $page), $filterhash);
    }

    # We have checked everywhere that can have metadata, so return the 
    # list of filters...
    return join(',', keys(%{$filterhash})) if(!$names);
}    


## @fn $ get_wiki_courses($wikiconfig)
# Obtain a list of courses in the specified wiki. This will log into the wiki and
# attempt to retrieve and parse the courses page stored on the wiki.
#
# @param wikiconfig A reference to the wiki's configuration object.
# @return A reference to a hash of course namespaces to titles..
sub get_wiki_courses {
    my $self       = shift;
    my $wikiconfig = shift;

    my $mw = MediaWiki::API -> new({ api_url => $wikiconfig -> {"WebUI"} -> {"api_url"} })
        or die "FATAL: Unable to create new MediaWiki API object.";

    # Log in using the 'internal' export user.
    $mw -> login( { lgname     => $wikiconfig -> {"WebUI"} -> {"username"}, 
                    lgpassword => $wikiconfig -> {"WebUI"} -> {"password"}})
        or die "FATAL: Unable to log into wiki. This is possibly a serious configuration error.\nAPI reported: ".$mw -> {"error"} -> {"code"}.': '. $mw -> {"error"} -> {"details"};

    # The contents of the course list page should now be accessible...
    my $coursepage = $mw->get_page( { title => $wikiconfig -> {"WebUI"} -> {"course_list"} } );

    # Do we have it?
    die "FATAL: Wiki configuration file specifies a course list page with no content."
        if($coursepage -> {"missing"} || !$coursepage -> {"*"});

    # We have something, so we want to parse out the contents
    my @courselist = $coursepage -> {"*"} =~ /(\[\[.*?\]\](?:\s*\(Filters: .*?\))?)/g;

    my $coursehash;
    # Process each course into the hash, using the namespace as the key
    foreach my $course (@courselist) {
        my ($ns, $title) = $course =~ /^(\w+):.*?\|(.*)$/;
        
        # Skip image/media just in case the user has an image on the page
        next if($ns eq "Image" || $ns eq "Media");

        # shove the results into the hash
        $coursehash -> {$ns} = $title;
    }
    
    # Probably not needed, but meh...
    $mw -> logout();

    return $coursehash;
}


# =============================================================================
#  Configuration interaction

## @fn $ get_wikiconfig_hash()
# Obtain a hash containing the processor configurations for the wikis the web ui
# knows how to talk to. The hash is keyed off the configuration filename, while
# the value of each is a ConfigMicro object.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return A hash of configurations.
sub get_wikiconfig_hash {
    my $self    = shift;
    my $confighash = {};

    # open the wiki configuration directory...
    opendir(CONFDIR, $self -> {"settings"} -> {"config"} -> {"wikiconfigs"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration dir: ".$self -> {"dbh"} -> errstr);

    while(my $entry = readdir(CONFDIR)) {
        # Skip anything that is obviously not config-like
        next unless($entry =~ /.config$/);

        # Try to load the config. This may well fail, but it's not fatal if it does...
        my $config = ConfigMicro -> new(path_join($self -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $entry))
            or $self -> {"logger"} -> warn_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration: ".$ConfigMicro::errstr);

        # If we actually have a config, store it
        $confighash -> {$entry} = $config if($config);
    }

    closedir(CONFDIR);

    return $confighash;
}


## @fn $ get_wiki_config($config_name)
# Load the configuration file for the specified wiki. This will load the config
# from the wiki configuration directory and return a reference to it.
#
# @param sysvars     A reference to a hash containing database, session, and settings objects.
# @param config_name The name of the wiki config to load. Should not contain any path!
# @return A reference to the wiki config object, or undef on failure.
sub get_wiki_config {
    my $self     = shift;
    my $config_name = shift;

    # Try to load the config. 
    my $config = ConfigMicro -> new(path_join($self -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $config_name))
        or $self -> {"logger"} -> warn_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration $config_name: ".$ConfigMicro::errstr);

    return $config;
}


## @fn $ set_error($error)
# Set the error string to the specified value. This updates the class error
# string and returns undef.
#
# @param error The message to set in the error string
# @return undef, always.
sub set_error {
    $errstr = shift;

    return undef;
}

1;
