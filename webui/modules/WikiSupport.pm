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


## @fn $ get_wiki_courses($wikiconfig)
# Obtain a list of courses in the specified wiki. This will log into the wiki and
# attempt to retrieve and parse the courses page stored on the wiki.
#
# @param wikiconfig A reference to the wiki's configuration object.
# @return A reference to a hash of course namespaces to titles..
sub get_wiki_courses {
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
    my @courselist = $coursepage -> {"*"} =~ /\[\[(.*?)\]\]/g;

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
