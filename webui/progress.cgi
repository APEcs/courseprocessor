#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend, progress log fetching script. This script
# fetches the export or processor progress logs for the current session, and
# after various transforms, spits it out as text for display in the webui's
# progress boxes.
#
# @version 1.0.0 (24 February 2011)
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
use lib qw(../modules);
#use utf8;

# System modules
use CGI;
use CGI::Compress::Gzip qw/:standard -utf8/;   # Enabling utf8 here is kinda risky, with the file uploads, but eeegh
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use DBI;
use File::Path qw(make_path);

# Custom modules
use ConfigMicro;
use Logger;
use SessionHandler;
use Utils qw(path_join load_file untaint_path read_pid);

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


## @fn $ process_running($pidfile)
# Check whether the process whose id is stored in the specified pidfile is still running.
#
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the process is running, undef otherwise.
sub process_running {
    my $pidfile = shift;

    # Does the pid file even exist? If not don't bother doing anything
    return 0 if(!-f $pidfile);

    # It exists, so we need to load it and see if the process is running
    my $pid = read_pid($pidfile);

    return $pid if(kill 0, $pid);

    return undef;
}


## @fn $ check_zip($sysvars, $pidfile)
# Determine whether the zip wrapper is currently working. This will determine whether the
# wrapper process is still alive, and return true if it is.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the wrapper is running, false otherwise.
sub check_zip {
    my $sysvars = shift;
    my $pidfile = shift || untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    # Is the wrapper running?
    my $running = process_running($pidfile);
    return $running if(defined($running));

    # get here and the task in the pid file is no longer present, so remove the file
    unlink $pidfile;

    return undef;
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

# Create or continue a session
my $session = SessionHandler -> new(logger   => $logger,
                                    cgi      => $out,
                                    dbh      => $dbh,
                                    settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# What mode are we in?
my $mode = $out -> param("mode");

# Fix up the mode for safety
$mode = "export" if(!$mode || ($mode ne "export" && $mode ne "process" && $mode ne "zipwrapper"));

# Work out some names and paths
my $outbase = path_join($settings -> {"config"} -> {"work_path"}, $session -> {"sessid"});
my $logfile = untaint_path(path_join($outbase, "$mode.log"));
my $pidfile = untaint_path(path_join($outbase, "$mode.pid"));

# if we are looking at the zipwrapper, we just need to send back whether
# it is currently working or finished
if($mode eq "zipwrapper") {
    my $status = check_zip({"logger"   => $logger,
                            "dbh"      => $dbh,
                            "settings" => $settings,
                            "cgi"      => $out}) ? "Working" : "Finished";

    print $out -> header(-type => 'text/plain');
    print $status;
} else {
    # Otherwise, send the contents of the log file to the user if possible
    if(-f $logfile) {
        my $data = load_file($logfile);

        print $out -> header(-type => 'text/plain');
        $data =~ s|<|&lt;|g;
        $data =~ s|>|&gt;|g;
        $data =~ s|\n|<br />\n|g; # explicitly force newlines
        $data =~ s|$outbase||g;   # remove scary/path exposing output

        # If we haven't hit a 'safe' exit case (FATAL or 'finished'), the process needs to be
        # running, or we have problems
        if(!process_running($pidfile) && $data !~ /FATAL:/ && $data !~ /Export finished/ && $data !~ /Processing complete/) {
            $data .= "FATAL: $mode script ended unexpectedly!<br/>\n";
        }

        # If we have colourisation enabled, do some
        if($settings -> {"config"} -> {"colour_progress"}) {
            $data =~ s|^(WARNING: .*?)$|<span class="warn">$1</span>|mg;
            $data =~ s|^(FATAL: .*?)$|<span class="error">$1</span>|mg;
        }

        print $data;
    } else {
        print $out -> header(-type => 'text/plain');
        print "No log file present.";
    }
}
