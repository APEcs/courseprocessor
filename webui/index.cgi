#!/usr/bin/perl -wT

use strict;
use lib qw(../modules);
use utf8;

# System modules
use CGI::Compress::Gzip qw/:standard -utf8/;   # Enabling utf8 here is kinda risky, with the file uploads, but eeegh
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use DBI;
use Digest;
use Encode;
use File::Copy;
use HTML::Entities;
use MIME::Base64;
use Time::HiRes qw(time);

# Custom modules
use ConfigMicro;
use Logger;
use SessionHandler;
use Template;
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

# IDs of the stages
use constant STAGE_LOGIN   => 0;
use constant STAGE_COURSE  => 1;
use constant STAGE_EXPORT  => 2;
use constant STAGE_PROCESS => 3;
use constant STAGE_FINISH  => 4;


# Stages in the process
my $stages = [ { "active"   => "templates/default/images/stage/login_active.png",
                 "inactive" => "templates/default/images/stage/login_inactive.png",
                 "passed"   => "templates/default/images/stage/login_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Log in",
                 "icon"     => "login",
                 "func"     => \&build_stage0_login },
               { "active"   => "templates/default/images/stage/options_active.png",
                 "inactive" => "templates/default/images/stage/options_inactive.png",
                 "passed"   => "templates/default/images/stage/options_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Choose course",
                 "icon"     => "course",
                 "hasback"  => 1,
                 "func"     => \&build_stage1_course },
               { "active"   => "templates/default/images/stage/export_active.png",
                 "inactive" => "templates/default/images/stage/export_inactive.png",
                 "passed"   => "templates/default/images/stage/export_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Export course",
                 "icon"     => "export",
                 "hasback"  => 1,
                 "func"     => \&build_stage2_export },
               { "active"   => "templates/default/images/stage/process_active.png",
                 "inactive" => "templates/default/images/stage/process_inactive.png",
                 "passed"   => "templates/default/images/stage/process_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Process course",
                 "icon"     => "process",
                 "hasback"  => 0,
                 "func"     => \&build_stage3_process },
               { "active"   => "templates/default/images/stage/finish_active.png",
                 "inactive" => "templates/default/images/stage/finish_inactive.png",
                 "passed"   => "templates/default/images/stage/finish_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Finish",
                 "icon"     => "finish",
                 "hasback"  => 0,
                 "func"     => \&build_stage4_finish } ];


# =============================================================================
#  Core page code and dispatcher

## @fn $ page_display($sysvars)
# Generate the contents of the page based on the current step in the wizard.
#
# @param sysvars A reference to a hash containing references to the template, 
#                database, settings, and cgi objects.
# @return A string containing the page to display.
sub page_display {
    my $sysvars = shift;
    my ($title, $body, $extrahead) = ("", "", "");

    # Get the current stage, and make it zero if there's no stage defined
    my $stage = is_defined_numeric($sysvars -> {"cgi"}, "stage");
    $stage = 0 if(!defined($stage));

    # Check that the stage is in range, fix it if not
    $stage = scalar(@$stages) - 1 if($stage >= scalar(@$stages));

    # some stages may provide a back button, in which case we may need to go back a stage if the back is pressed...
    if(defined($sysvars -> {"cgi"} -> param('back')) && $stage > 0 && $stages -> [$stage - 1] -> {"hasback"}) {
        my $bstage = is_defined_numeric($sysvars -> {"cgi"}, "bstage");
        $stage = $bstage if(defined($bstage));
    }

    # Do we have a function?
    my $func = $stages -> [$stage] -> {"func"}; # these two lines could be done in one, but it would look horrible...
    ($title, $body, $extrahead) = $func -> ($sysvars) if($func);
    
    return $sysvars -> {"template"} -> load_template("page.tem", 
                                                     { "***title***"     => $title,
                                                       "***extrahead***" => $extrahead,
                                                       "***core***"      => $body || '<p class="error">No page content available, this should not happen.</p>'});
}


my $starttime = time();

# Create a new CGI object to generate page content through
my $out = CGI::Compress::Gzip -> new();

# And a logger for... logging stuff
$logger = Logger -> new();

# Load the system config
my $settings = ConfigMicro -> new("config/site.cfg")
    or $logger -> die_log($out -> remote_host(), "index.cgi: Unable to obtain configuration file: ".$ConfigMicro::errstr);

# Database initialisation. Errors in this will kill program.
$dbh = DBI->connect($settings -> {"database"} -> {"database"},
                    $settings -> {"database"} -> {"username"},
                    $settings -> {"database"} -> {"password"},
                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or $logger -> die_log($out -> remote_host(), "index.cgi: Unable to connect to database: ".$DBI::errstr);

# Pull configuration data out of the database into the settings hash
$settings -> load_db_config($dbh, $settings -> {"database"} -> {"settings"});

# Start doing logging if needed
$logger -> start_log($settings -> {"config"} -> {"logfile"}) if($settings -> {"config"} -> {"logfile"});

# Create the template handler object
my $template = Template -> new(basedir => path_join($settings -> {"config"} -> {"base"}, "templates"))
    or die_log($out -> remote_host(), "Unable to create template handling object: ".$Template::errstr);

# Create or continue a session
my $session = SessionHandler -> new(cgi      => $out, 
                                    dbh      => $dbh,
                                    template => $template,
                                    settings => $settings)
    or die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# Generate the page based on the current step
my $content = page_display({"logger"   => $logger,
                            "session"  => $session,
                            "template" => $template,
                            "dbh"      => $dbh,
                            "settings" => $settings,
                            "cgi"      => $out});

# And start the printing process
print $out -> header(-charset => 'utf-8',
                     -cookie  => $session -> session_cookies());

my $endtime = time();
my ($user, $system, $cuser, $csystem) = times();
my $debug = $template -> load_template("debug.tem", {"***secs***"   => sprintf("%.2f", $endtime - $starttime),
                                                     "***user***"   => $user,
                                                     "***system***" => $system,
                                                     "***memory***" => $template -> bytes_to_human(get_proc_size())});
                                                     
print Encode::encode_utf8($template -> process_template($content, {"***debug***" => $debug}));
$template -> set_module_obj(undef);
