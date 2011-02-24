#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend garbage collector. This should be called
# from a cron job (every 10 minutes is probably sufficient) to clean out any
# expired session temporary directories and files.
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
use lib ("$path/../modules");

# System modules
use DBI;

# Custom modules
use ConfigMicro;
use Logger;
use Utils qw(path_join untaint_path);

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


## @fn void prune_old_dirs($sysvars, $path)
# Remove any directories in the specified path that do not have a valid session
# associated with them.
#
# @param sysvars A reference to a hash containing database, logger, and settings objects.
# @param path    The path to look for directories in.
sub prune_old_dirs {
    my $sysvars = shift;
    my $path    = shift;

    # If the directory does not exist, do nothing
    return if(!-d $path);

    # Prepare a query to use when checking directories
    my $sess_check = $sysvars -> {"dbh"} -> prepare("SELECT id FROM ".$sysvars -> {"settings"} -> {"database"} -> {"sessions"}.
                                                    " WHERE session_id = ?");
    
    opendir(PATH, $path)
        or $sysvars -> {"logger"} -> die_log("internal", "FATAL: Unable to open directory for reading: $!");

    while(my $entry = readdir(PATH)) {
        next if($entry eq "." || $entry eq ".."); # skip current and parent

        my $fullpath = untaint_path(path_join($path, $entry));

        # only bother checking directories
        if(-d $fullpath) {
            # Does the entry correspond to a session?
            $sess_check -> execute($entry)
                or $sysvars -> {"logger"} -> die_log("internal", "Unable to determine whether directory entry has a valid session: ".$sysvars -> {"dbh"} -> errstr);

            my $sess_row = $sess_check -> fetchrow_arrayref();

            # If we have no row, kill the directory
            `$sysvars->{settings}->{paths}->{rm} -rf $fullpath` unless($sess_row);
        }
    }

    closedir(PATH);

}


## @fn void garbage_collect($sysvars)
# Clean out any old session directories from the temporary directory and output 
# directory. This will entirely remove any directories that do not have a current
# session associated with them.
#
# @param sysvars A reference to a hash containing database, logger, and settings objects.
sub garbage_collect {
    my $sysvars = shift;
    my $now     = time();

    prune_old_dirs($sysvars, untaint_path($sysvars -> {"settings"} -> {"config"} -> {"work_path"}));
    prune_old_dirs($sysvars, untaint_path($sysvars -> {"settings"} -> {"config"} -> {"output_path"}));
}


# A logger for... logging stuff
$logger = Logger -> new();

# Load the system config
my $settings = ConfigMicro -> new("$path/config/site.cfg")
    or $logger -> die_log("internal", "Unable to obtain configuration file: ".$ConfigMicro::errstr);

# Database initialisation. Errors in this will kill program.
$dbh = DBI->connect($settings -> {"database"} -> {"database"},
                    $settings -> {"database"} -> {"username"},
                    $settings -> {"database"} -> {"password"},
                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or $logger -> die_log("internal", "Unable to connect to database: ".$DBI::errstr);

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

# Clean up any old directories
garbage_collect({"logger"   => $logger,
                 "dbh"      => $dbh,
                 "settings" => $settings});
