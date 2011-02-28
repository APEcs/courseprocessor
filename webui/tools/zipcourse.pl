#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend, zip wrapper. This script is needed
# to allow the processor frontend to zip a processed course up into a form
# the user may download.
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
use utf8;

use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}
use lib ("$path/../../modules");

# System modules
use DBI;
use XML::Simple;

# Custom modules
use ConfigMicro;
use Logger;
use Utils qw(path_join untaint_path lead_zero write_pid);

my $dbh;                                   # global database handle, required here so that the END block can close the database connection
my $logger;                                # global logger handle, so that logging can be closed in END

BEGIN {
    $ENV{"PATH"} = ""; # Force no path.
    
    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)}; # Clean up ENV
}
END {
    # Nicely close the database connection. Possibly not vital, but good to be sure..
    $dbh -> disconnect() if($dbh);

    # Stop logging if it has been enabled.
    $logger -> end_log() if($logger);
}


# The session id should have been provided as the first argument to the script, and the course
# name as the second
die "Usage: zipcourse.pl <sessionid> <course>\n" 
    unless($ARGV[0] && $ARGV[0] =~ /^[a-fA-F0-9]{32}$/ &&
           $ARGV[1] && $ARGV[1] =~ /^\w+$/);

# A logger for... logging stuff
$logger = Logger -> new();

# Load the system config
my $settings = ConfigMicro -> new("$path/../config/site.cfg")
    or $logger -> die_log("internal", "Unable to obtain configuration file: ".$ConfigMicro::errstr);

# Database initialisation. Errors in this will kill program.
$dbh = DBI->connect($settings -> {"database"} -> {"database"},
                    $settings -> {"database"} -> {"username"},
                    $settings -> {"database"} -> {"password"},
                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or $logger -> die_log("internal", "Unable to connect to database: ".$DBI::errstr);

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

# Okay, we're running, so store the pid
write_pid(untaint_path(path_join($settings -> {"config"} -> {"work_path"}, $ARGV[0], "zipwrapper.pid")));

# Now calculate paths we will need
my $basedir = untaint_path(path_join($settings -> {"config"} -> {"output_path"}, $ARGV[0]));
my $output  = untaint_path($ARGV[1]);

my @now = localtime();
my $zipname = untaint_path($ARGV[1].".zip");

chdir $basedir;

# Remove the zip file if it exists, for safety
unlink $zipname;

# Do the zip
print `$settings->{paths}->{zip} -r9 $zipname $output`;

