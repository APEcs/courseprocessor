#!/usr/bin/perl -w

# Update the javascript directory link to include the ID of the latest git commit.
# This allows the javascript directory to be updated, forcing clients to load the
# new scripts rather than using cached versions.

use strict;
use v5.14;
use experimental qw(smartmatch);
use lib "/var/www/webperl";
use lib "../modules";

use DBI;
use Data::Dumper;

use Webperl::ConfigMicro;
use Webperl::Logger;
use Webperl::Utils qw(path_join);

my $logger = Webperl::Logger -> new()
        or die "FATAL: Unable to create logger object\n";

my $settings = Webperl::ConfigMicro -> new("../config/site.cfg")
    or die "Unable to open configuration file: ".$Webperl::SystemModule::errstr."\n";

die "No 'language' table defined in configuration, unable to proceed.\n"
    unless($settings -> {"database"} -> {"language"});

my $dbh = DBI->connect($settings -> {"database"} -> {"database"},
                       $settings -> {"database"} -> {"username"},
                       $settings -> {"database"} -> {"password"},
                       { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or die "Unable to connect to database: ".$DBI::errstr."\n";

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

my $tempath = path_join($settings -> {"config"} -> {"base"}, "templates", $settings -> {"config"} -> {"default_style"});
chdir($tempath)
    or die "Unable to change to '$tempath': $!\n";

# Determine the latest git commit ID
my $ID = `/usr/bin/git rev-parse --short HEAD`;
die "Unable to get latest commit ID from git. Result was '$ID'"
    unless($ID =~ /^[a-f0-9]+$/);

# The ID will usually have a newline on the end
chomp($ID);

# Remove old links
`rm js_*`;
`rm css_*`;

# Set up the new link
my $err = `ln -s js js_$ID`;
die "Link creation failed: $err\n" if($err);

$err = `ln -s css css_$ID`;
die "Link creation failed: $err\n" if($err);

# And update the config with the new id
$settings -> set_db_config("jsdirid", $ID);

print "Updated javascript directory to js_$ID\nUpdated stylesheet directory to css_$ID\n";
