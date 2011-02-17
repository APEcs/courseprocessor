#!/usr/bin/perl -wT

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
use Utils qw(path_join is_defined_numeric get_proc_size);

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

# Create or continue a session
my $session = SessionHandler -> new(logger   => $logger,
                                    cgi      => $out, 
                                    dbh      => $dbh,
                                    settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# What mode are we in?
my $mode = $out -> param("mode");

# Fix up the mode for safety
$mode = "export" if(!$mode || ($mode ne "export" && $mode ne "process"));

# Work out some names and paths
my $outbase = path_join($settings -> {"config"} -> {"work_path"}, $session -> {"sessid"});
my $logfile = path_join($outbase, "$mode.log");

# Send the contents of the log file to the user if possible
if(-f $logfile) {
    open(LOGFILE, $logfile)
        or die_log($out -> remote_host(), "progress.cgi: Unable to open log file: $!");

    print $out -> header(-type => 'text/plain');
    my $data;
    while(read(LOGFILE, $data, 4096)) {
        $data =~ s|\n|<br />\n|g;
        print $data;
    }

    close(LOGFILE);
} else {
    print $out -> header(-type => 'text/plain');
    print "No log file present.";
}
