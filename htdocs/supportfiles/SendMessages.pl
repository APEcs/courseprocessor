#!/usr/bin/perl -wT

use strict;
use lib qw(/var/www/webperl);
use lib qw(../modules);
use utf8;

# System modules
use DBI;
use Modules;
use ConfigMicro;
use Logger;
use Message::Queue;

my $logger = Logger -> new()
    or die "FATAL: Unable to create logger object";

# Load the system config
my $settings = ConfigMicro -> new("../config/site.cfg")
    or $logger -> die_log("Not avilable", "SendMessages.pl: Unable to obtain configuration file: ".$ConfigMicro::errstr);

    # Database initialisation. Errors in this will kill program.
my $dbh = DBI->connect($settings -> {"database"} -> {"database"},
                                    $settings -> {"database"} -> {"username"},
                                    $settings -> {"database"} -> {"password"},
                                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or $logger -> die_log("None", "SendMessages.pl: Unable to connect to database: ".$DBI::errstr);

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

# Start database logging if available
$logger -> init_database_log($dbh, $settings -> {"database"} -> {"logging"})
    if($settings -> {"database"} -> {"logging"});

# Start doing logging if needed
$logger -> start_log($settings -> {"config"} -> {"logfile"}) if($settings -> {"config"} -> {"logfile"});

my $messages = Message::Queue -> new(logger   => $logger,
                                     dbh      => $dbh,
                                     settings => $settings)
    or $logger -> die_log("none", "SendMessages.pl: Unable to create message handler: ".$SystemModule::errstr);

my $module = Modules -> new(logger   => $logger,
                            dbh      => $dbh,
                            settings => $settings)
    or $logger -> die_log("none", "SendMessages.pl: Unable to create module loader: ".$SystemModule::errstr);

$messages -> set_module_obj($module);

$messages -> deliver_queue($ARGV[0]);
