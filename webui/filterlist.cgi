#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend, filter enumerator. This script
# fetches the list of filters for the course specified in the query
# string.
#
# @version 1.0.0 (11 March 2011)
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
#

use strict;
#use utf8;

# Add the paths to custom modules to the include list
use lib qw(../modules);
use lib qw(modules);
use lib qw(/var/www/webperl); # and to webperl

# System modules
use CGI;
use CGI::Compress::Gzip qw/:standard -utf8/;   # Enabling utf8 here is kinda risky, with the file uploads, but eeegh
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use DBI;
use File::Path qw(make_path);

# Custom modules
use Auth;
use AppUser;
use ConfigMicro;
use Logger;
use SessionHandler;
use SessionSupport;
use WikiSupport;

my $dbh;                                   # global database handle, required here so that the END block can close the database connection
my $logger;                                # global logger handle, so that logging can be closed in END
my $contact = 'webmaster@starforge.co.uk'; # global contact address, for error messages

# install more useful error handling
BEGIN {
    $ENV{"PATH"} = ""; # Force no path.

    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)}; # Clean up ENV
    sub handle_errors {
        my $msg = shift;
        print "<h1>Software error</h1>\n";
        print '<p>Server time: ',scalar(localtime()),'<br/>Error was:</p><pre>',$msg,'</pre>';
        print '<p>Please report this error to ',$contact,' giving the text of this error and the time and date at which it occured</p>';
    }
    set_message(\&handle_errors);
}
END {
    # Nicely close the database connection. Possibly not vital, but good to be sure..
    $dbh -> disconnect() if($dbh);

    # Stop logging if it has been enabled.
    $logger -> end_log() if($logger);
}


# A logger for... logging stuff
$logger = Logger -> new();

# Load the system config
my $settings = ConfigMicro -> new("config/site.cfg")
    or $logger -> die_log("internal", "index.cgi: Unable to obtain configuration file: ".$ConfigMicro::errstr);

# Database initialisation. Errors in this will kill program.
$dbh = DBI->connect($settings -> {"database"} -> {"database"},
                    $settings -> {"database"} -> {"username"},
                    $settings -> {"database"} -> {"password"},
                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or $logger -> die_log("internal", "index.cgi: Unable to connect to database: ".$DBI::errstr);

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

# Create a new CGI object to generate page content through
my $out;
if($settings -> {"config"} -> {"compress_output"}) {
    # If compression is enabled, use the gzip compressed cgi...
    $out = CGI::Compress::Gzip -> new();
} else {
    # Otherwise use bog-standard, perhaps the http(s) stack will compress for us
    $out = CGI -> new();
}

# Create something to help out with wiki interaction
my $wiki = WikiSupport -> new(logger   => $logger,
                              cgi      => $out,
                              dbh      => $dbh,
                              settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create wiki support object: ".$WikiSupport::errstr);

# Need auth and application setup...
my $app = AppUser -> new(logger   => $logger,
                         cgi      => $out,
                         dbh      => $dbh,
                         settings => $settings);
my $auth = Auth -> new();

$auth -> init($out, $dbh, $app, $settings, $logger);

# Create or continue a session
my $session = SessionHandler -> new(logger   => $logger,
                                    cgi      => $out,
                                    dbh      => $dbh,
                                    settings => $settings,
                                    auth     => $auth)
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# And the support object to provide webui specific functions
my $sess_support = SessionSupport -> new(logger   => $logger,
                                         cgi      => $out,
                                         dbh      => $dbh,
                                         settings => $settings,
                                         session  => $session)
    or $logger -> die_log($out -> remote_host(), "Unable to create session support object: ".$SessionSupport::errstr);

# Get the course parameter...
my $coursearg = $out -> param("course") || "";

# Make sure it is valid..
my ($course) = $coursearg =~ /^(\w+)$/;

print $out -> header(-type => 'text/plain');

# Only bother trying to get a list if we have a course
if($course) {
    # We need wiki config stuff...
    my ($config_name, $wiki_user) = $sess_support -> get_sess_login();

    if($config_name) {
        # Obtain the wiki's configuration
        my $wikiconfig = $wiki -> get_wiki_config($config_name);

        print $wiki -> get_course_filters($wikiconfig, $course) if($wikiconfig);
    }
}
