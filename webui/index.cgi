#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend. This script provides a user-friendly,
# if not entirely user-obsequious, web-based frontend to the APEcs course
# processor and wiki export tools.
#
# @version 1.0.4 (9 March 2011)
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
use CGI qw/:standard -utf8/;                   # Ensure that both CGI and the compressed version are loaded with utf8 enabled.
use CGI::Compress::Gzip qw/:standard -utf8/;
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use DBI;
use Digest;
use Encode;
use File::Copy;
use File::Path qw(make_path);
use HTML::Entities;
use MIME::Base64;
use Time::HiRes qw(time);

# Custom modules
use Auth;
use AppUser;
use ConfigMicro;
use FormValidators;
use Logger;
use SessionHandler;
use SessionSupport;
use Template;
use Utils qw(path_join is_defined_numeric get_proc_size read_pid untaint_path);
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

# IDs of the stages
use constant STAGE_WELCOME => 0;
use constant STAGE_LOGIN   => 1;
use constant STAGE_COURSE  => 2;
use constant STAGE_EXPORT  => 3;
use constant STAGE_PROCESS => 4;
use constant STAGE_FINISH  => 5;


# Stages in the process
my $stages = [ { "active"   => "templates/default/images/stages/welcome_active.png",
                 "inactive" => "templates/default/images/stages/welcome_inactive.png",
                 "passed"   => "templates/default/images/stages/welcome_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Welcome",
                 "icon"     => "welcome",
                 "func"     => \&build_stage0_welcome },
               { "active"   => "templates/default/images/stages/login_active.png",
                 "inactive" => "templates/default/images/stages/login_inactive.png",
                 "passed"   => "templates/default/images/stages/login_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Log in",
                 "icon"     => "login",
                 "func"     => \&build_stage1_login },
               { "active"   => "templates/default/images/stages/course_active.png",
                 "inactive" => "templates/default/images/stages/course_inactive.png",
                 "passed"   => "templates/default/images/stages/course_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Choose course",
                 "icon"     => "course",
                 "hasback"  => 1,
                 "func"     => \&build_stage2_course },
               { "active"   => "templates/default/images/stages/export_active.png",
                 "inactive" => "templates/default/images/stages/export_inactive.png",
                 "passed"   => "templates/default/images/stages/export_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Export course",
                 "icon"     => "export",
                 "hasback"  => 1,
                 "func"     => \&build_stage3_export },
               { "active"   => "templates/default/images/stages/process_active.png",
                 "inactive" => "templates/default/images/stages/process_inactive.png",
                 "passed"   => "templates/default/images/stages/process_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Process course",
                 "icon"     => "process",
                 "hasback"  => 1,
                 "func"     => \&build_stage4_process },
               { "active"   => "templates/default/images/stages/finish_active.png",
                 "inactive" => "templates/default/images/stages/finish_inactive.png",
                 "passed"   => "templates/default/images/stages/finish_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Finish",
                 "icon"     => "finish",
                 "hasback"  => 1,
                 "func"     => \&build_stage5_finish } ];

# =============================================================================
#  Form list/dropdown creation

## @fn $ make_wikiconfig_select($sysvars, $wikihash, $default)
# Create a select box using the contents of the wiki hash provided. This will create
# a list of wikis the user may select from, with an optional default selection.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @param wikihash A reference to a hash containing the wiki configurations
# @param default  The name of the initially selected wiki, or undef.
# @return A string containing the select box to show to the user.
sub make_wikiconfig_select {
    my $sysvars  = shift;
    my $wikihash = shift;
    my $default  = shift;

    my $options = "";
    foreach my $wiki (sort(keys(%{$wikihash}))) {
        $options .= "<option value=\"$wiki\"";
        $options .= ' selected="selected"' if($default && $wiki eq $default);
        $options .= ">".$wikihash -> {$wiki} -> {"WebUI"} -> {"name"}." (".$wikihash -> {$wiki} -> {"wiki2course"} -> {"wiki_url"}.")</option>\n";
    }

    return $sysvars -> {"template"} -> load_template("webui/wiki_select.tem", {"***entries***" => $options});
}


## @fn $ make_course_select($sysvars, $coursehash, $default)
# Generate a select box using the contents of the course hash provided. This will
# create a list of courses the user may select from, with an optional default
# selection.
#
# @param sysvars    A reference to a hash containing database, session, and settings objects.
# @param coursehash A reference to a hash containing the courses.
# @param default    The name of the initially selected course, or undef.
# @return A string containing the select box to show to the user.
sub make_course_select {
    my $sysvars    = shift;
    my $coursehash = shift;
    my $default    = shift;

    my $options = "";
    foreach my $ns (sort {$coursehash -> {$a} cmp $coursehash -> {$b}} (keys(%{$coursehash}))) {
        $options .= "<option value=\"$ns\"";

        # If we have no default, make one
        $default = $ns if(!$default);

        $options .= ' selected="selected"' if($default && $ns eq $default);
        $options .= ">".$coursehash -> {$ns}."</option>\n";
    }

    return $options;
}


# =============================================================================
#  Shell interaction

## @fn void launch_exporter($sysvars, $wikiconfig, $course)
# Start the wiki2course exporter script working in the background to fetch the
# contents of the specified course from the wiki.
#
# @param sysvars     A reference to a hash containing database, session, and settings objects.
# @param wikiconfig  A reference to the wiki configuration object.
# @param config_name The name of the configuration for the wiki.
# @param course      The namespace of the course to export.
sub launch_exporter {
    my $sysvars     = shift;
    my $wikiconfig  = shift;
    my $config_name = shift;
    my $course      = shift;

    # Work out some names and paths needed later
    my $outbase = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}));
    my $logfile = path_join($outbase, "export.log");
    my $outpath = path_join($outbase, "coursedata");
    my $pidfile = path_join($outbase, "export.pid");

    # Make sure the paths exist
    if(!-d $outpath) {
        eval { make_path($outpath); };
        $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to create temporary output dir $outpath: $!") if($@);
    }

    my $extraverb = "";
    $extraverb = "-v" if($sysvars -> {"sess_supp"} -> get_sess_verbosity("export"));

    my $cmd = $sysvars -> {"settings"} -> {"paths"} -> {"nohup"}." ".$sysvars -> {"settings"} -> {"paths"} -> {"wiki2course"}." -v $extraverb".
              " -u ".$wikiconfig -> {"WebUI"} -> {"username"}.
              " -p ".$wikiconfig -> {"WebUI"} -> {"password"}.
              " -n $course".
              " -o $outpath".
              " -w ".$wikiconfig -> {"wiki2course"} -> {"api_url"}.
              " -g ".untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $config_name)).
              " --pid $pidfile".
              " > $logfile".
              ' 2>&1 &';

    # Set the exporter going, hopefully unattached in the background now...
    `$cmd`;
}


## @fn $ check_exporter($sysvars, $pidfile)
# Determine whether the exporter is currently working. This will determine whether the
# exporter process is still alive, and return true if it is.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the exporter is running, false otherwise.
sub check_exporter {
    my $sysvars = shift;
    my $pidfile = shift || untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "export.pid"));

    # Does the pid file even exist? If not don't bother doing anything
    return 0 if(!-f $pidfile);

    # It exists, so we need to load it and see if the process is running
    my $pid = read_pid($pidfile);

    return $pid if(kill 0, $pid);

    return undef;
}


## @fn $ halt_exporter($sysvars)
# Determine whether the exporter is still working, and if it is kill it. This will
# attempt to load the PID file for the exporter, and kill the process specified in
# it if the process is running, otherwise it will simply delete the file.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return true if the exporter was running and has been killed, false otherwise.
sub halt_exporter {
    my $sysvars = shift;

    my $pidfile = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "export.pid"));

    # Is the exporter still going?
    my $pid = check_exporter($sysvars, $pidfile);

    # Remove the no-longer-needed pid file
    unlink($pidfile);

    # If the process is running, try to kill it
    # We could probably use TERM rather than KILL, but this can't be blocked...
    return kill 9,$pid if($pid);

    return 0;
}


## @fn void launch_processor($sysvars, $config_name)
# Start the processor script working in the background to convert the fetched course
# into a CBT package.
#
# @param sysvars     A reference to a hash containing database, session, and settings objects.
# @param config_name The name of the configuration for the wiki.
sub launch_processor {
    my $sysvars     = shift;
    my $config_name = shift;

    # Work out some names and paths needed later
    my $outbase    = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}));
    my $logfile    = path_join($outbase, "process.log");
    my $coursedata = path_join($outbase, "coursedata");
    my $pidfile    = path_join($outbase, "process.pid");
    my $outpath    = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"output_path"}, $sysvars -> {"session"} -> {"sessid"}, $sysvars -> {"sess_supp"} -> get_sess_course()));

    # Make sure the output path exist
    if(!-d $outpath) {
        eval { make_path($outpath); };
        $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to create output dir $outpath: $!") if($@);
    }

    # Has the user enabled additional verbosity?
    my $extraverb = "";
    $extraverb = "-v" if($sysvars -> {"sess_supp"} -> get_sess_verbosity("process"));

    # Do we need to provide any additional arguments to the output handler?
    my $outargs = "";
    my $templates = $sysvars -> {"sess_supp"} -> get_sess_templates();
    $outargs .= "--outargs templates:$templates" if($templates);

    # Do we need to provide filters?
    my $filters = $sysvars -> {"sess_supp"} -> get_sess_filters() || "";
    $filters = "--filter=$filters" if($filters);

    my $cmd = $sysvars -> {"settings"} -> {"paths"} -> {"nohup"}." ".$sysvars -> {"settings"} -> {"paths"} -> {"processor"}." -v $extraverb $outargs $filters".
              " -c $coursedata".
              " -d $outpath".
              " -f ".untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $config_name)).
              " --pid $pidfile".
              " > $logfile".
              ' 2>&1 &';

    # Set the processor going, hopefully unattached in the background now...
    `$cmd`;
}


## @fn $ check_processor($sysvars, $pidfile)
# Determine whether the processor is currently working. This will determine whether the
# processor process is still alive, and return true if it is.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the exporter is running, false otherwise.
sub check_processor {
    my $sysvars = shift;
    my $pidfile = shift || untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "process.pid"));

    # Does the pid file even exist? If not don't bother doing anything
    return 0 if(!-f $pidfile);

    # It exists, so we need to load it and see if the process is running
    my $pid = read_pid($pidfile);

    return $pid if(kill 0, $pid);

    return undef;
}


## @fn $ halt_processor($sysvars)
# Determine whether the processor is still working, and if it is kill it. This will
# attempt to load the PID file for the processor, and kill the process specified in
# it if the process is running, otherwise it will simply delete the file.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return true if the exporter was running and has been killed, false otherwise.
sub halt_processor {
    my $sysvars = shift;

    my $pidfile = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "process.pid"));

    # Is the processor still going?
    my $pid = check_processor($sysvars, $pidfile);

    # Remove the no-longer-needed pid file
    unlink($pidfile);

    # If the process is running, try to kill it
    # We could probably use TERM rather than KILL, but this can't be blocked...
    return kill 9,$pid if($pid);

    return 0;
}


## @fn void launch_zip($sysvars)
# Start the zip script to pack the course into a zip file the user can download.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
sub launch_zip {
    my $sysvars = shift;

    my $outbase = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}));
    my $logfile = path_join($outbase, "zipwrapper.log");

    my $cname = $sysvars -> {"sess_supp"} -> get_sess_course();
    my ($name) = $cname =~ /^(\w+)$/;

    my $sessid = $sysvars -> {"session"} -> {"sessid"};
    my ($sid) = $sessid =~ /^([a-fA-F0-9]{32})$/;

    # Create the command to launch the zippery
    my $cmd = $sysvars -> {"settings"} -> {"paths"} -> {"nohup"}." ".$sysvars -> {"settings"} -> {"config"} -> {"base"}."/tools/zipcourse.pl".
        " $sid $name".
        " > $logfile".
        ' 2>&1 &';

    # Start it going...
    `$cmd`;
}


## @fn $ check_zip($sysvars, $pidfile)
# Determine whether the zip wrapper is currently working. This will determine whether the
# wrapper process is still alive, and return true if it is.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the exporter is running, false otherwise.
sub check_zip {
    my $sysvars = shift;
    my $pidfile = shift || untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    # Does the pid file even exist? If not don't bother doing anything
    return 0 if(!-f $pidfile);

    # It exists, so we need to load it and see if the process is running
    my $pid = read_pid($pidfile);

    return $pid if(kill 0, $pid);

    return undef;
}


## @fn $ halt_zip($sysvars)
# Determine whether the zip wrapper is still working, and if it is kill it. This will
# attempt to load the PID file for the zip wrapper, and kill the process specified in
# it if the process is running, otherwise it will simply delete the file.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return true if the exporter was running and has been killed, false otherwise.
sub halt_zip {
    my $sysvars = shift;

    my $pidfile = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    # Is the processor still going?
    my $pid = check_zip($sysvars, $pidfile);

    # Remove the no-longer-needed pid file
    unlink($pidfile);

    # If the process is running, try to kill it
    # We could probably use TERM rather than KILL, but this can't be blocked...
    return kill 9,$pid if($pid);

    return 0;
}


# =============================================================================
#  Stages...

## @fn @ build_stage0_welcome($sysvars)
# Generate the first stage of the wizard - a simple page describing the application
# and the process.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage0_welcome {
    my $sysvars = shift;

    # All we need to do here is generate the title and message...
    my $title    = $sysvars -> {"template"} -> replace_langvar("WELCOME_TITLE");
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("WELCOME_TITLE"),
                                                          $stages -> [STAGE_WELCOME] -> {"icon"},
                                                          $stages, STAGE_WELCOME,
                                                          $sysvars -> {"template"} -> replace_langvar("WELCOME_LONGDESC"),
                                                          $sysvars -> {"template"} -> load_template("webui/stage0form.tem"));
    return ($title, $message);
}


## @fn @ build_stage1_login($sysvars, $error)
# Generate the form through which the user can provide their login details and select
# the wiki that they want to export courses from. This will optionally display an error
# message before the form if the second parameter is set. Note that this stage does no
# processing of the login, it simply generates the login form.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @param error    An optional error message string to show in the form.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage1_login {
    my $sysvars = shift;
    my $error   = shift;

    # First, remove the 'logged in' marker
    $sysvars -> {"sess_supp"} -> clear_sess_login();

    # Get a hash of wikis we know how to talk to
    my $wikis = $sysvars -> {"wiki"} -> get_wikiconfig_hash();

    # And has the user selected one?
    my $setwiki = $sysvars -> {"cgi"} -> param("wiki");

    # Convert the hash to a select...
    my $wikiselect = make_wikiconfig_select($sysvars, $wikis, $setwiki);

    # Do we have a username, and is it valid?
    my $username = $sysvars -> {"cgi"} -> param("username");
    $username = "" if(!$username || $username !~ /^\w+$/);

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("LOGIN_TITLE");
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("LOGIN_TITLE"),
                                                          $error ? "warn" : $stages -> [STAGE_LOGIN] -> {"icon"},
                                                          $stages, STAGE_LOGIN,
                                                          $sysvars -> {"template"} -> replace_langvar("LOGIN_LONGDESC"),
                                                          $sysvars -> {"template"} -> load_template("webui/stage1form.tem", {"***error***"    => $error,
                                                                                                                             "***wikis***"    => $wikiselect,
                                                                                                                             "***username***" => $username}));
    return ($title, $message);
}


## @fn @ do_stage1_login($sysvars)
# Process the values submitted by the user on the login form. This will attempt to log
# the user into the wiki they have selected using their supplied credentials, and if
# it succeeds this will return undef. If the login fails, either because no wiki has
# been selected, or the login details are missing or invalid, it will return the
# title and message box to show on the page.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @return undef on success, otherwise an array of two elements: the page title, and the
#         message box to show to the user.
sub do_stage1_login {
    my $sysvars = shift;

    # Get the wiki the user selected, if they did
    my $setwiki = $sysvars -> {"cgi"} -> param("wiki");

    # Yes - do we have a wiki selected?
    if($setwiki) {
        # Get a hash of wikis we know how to talk to
        my $wikis = $sysvars -> {"wiki"} -> get_wikiconfig_hash();

        # Is the wiki valid?
        if($setwiki =~ /^\w+\.config$/ && $wikis -> {$setwiki}) {
            # Do we have login details? If so, try to validate them...
            if($sysvars -> {"cgi"} -> param("username") && $sysvars -> {"cgi"} -> param("password")) {
                if($sysvars -> {"wiki"} -> check_wiki_login($sysvars -> {"cgi"} -> param("username"),
                                                            $sysvars -> {"cgi"} -> param("password"),
                                                            $wikis -> {$setwiki})) {
                    $sysvars -> {"sess_supp"} -> set_sess_login($setwiki, $sysvars -> {"cgi"} -> param("username"));
                    return (undef, undef);

                } else { #if(check_wiki_login($sysvars -> {"cgi"} -> param("username"), $sysvars -> {"cgi"} -> param("password")))
                    # User login failed
                    return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_BADLOGIN"));
                }
            } else { # if($sysvars -> {"cgi"} -> param("username") && $sysvars -> {"cgi"} -> param("password"))
                # No user details entered.
                return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_NOLOGIN"));
            }
        } else { # if($setwiki =~ /^[\w].config/ && $wikis -> {$setwiki})
            # Wiki selection is not valid
            return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_BADWIKI"));
        }
    } else { # if($setwiki)
        # User has not selected a wiki
        return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_NOWIKI"));
    }

    return undef;
}


## @fn @ build_stage2_course($sysvars, $error)
# Generate the form through which the user can select the course to export and process.
# This will query the wiki the user selected in stage 1 for a list of courses, and it
# will generate a list from which the user can select a course. It can also optionally
# display an error message if the second parameter is set. As with stage1, no processing
# of the selection is done here.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @param error    An optional error message string to show in the form.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage2_course {
    my $sysvars = shift;
    my $error   = shift;

    # did the user submit from login?
    if($sysvars -> {"cgi"} -> param("dologin")) {
        # Yes, attempt to process the login. Also, why can't perl have a 'returnif' so this could be
        # returnif do_stage0_login($sysvars);, damnit.
        my @result = do_stage1_login($sysvars);
        return @result if($result[0] && $result[1]);

    # did the user click back?
    } elsif($sysvars -> {"cgi"} -> param("back")) {
        # Yes, check that the exporter is not running, and kill it if it is.
        halt_exporter($sysvars);

        # We can also get here from processing, so check and halt that if needed
        halt_processor($sysvars);

        # And we can get here from the final step too, so check whether the zip
        # wrapper is running, and kill it if needed
        halt_zip($sysvars);
    }

    # If the user has logged in successfully, obtain a list of courses from the wiki.
    my ($config_name, $wiki_user) = $sysvars -> {"sess_supp"} -> get_sess_login()
        or return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_FAILWIKI"));

    # Obtain the wiki's configuration
    my $wiki = $sysvars -> {"wiki"} -> get_wiki_config($config_name);

    # Get the list of courses
    my $courses = $sysvars -> {"wiki"} -> get_wiki_courses($wiki);

    # And convert to a select box
    my $courselist = make_course_select($sysvars, $courses, $sysvars -> {"cgi"} -> param("course"));

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($wiki -> {"wiki2course"} -> {"course_page"} || "Course"),
                     "***lccourse***" => lc($wiki -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Do we need to make a template block?
    my $templateblock = "";
    if($wiki -> {$wiki -> {"Processor"} -> {"output_handler"}} -> {"templatelist"}) {
        # Split the list of templates up
        my @templates = split(/,/, $wiki -> {$wiki -> {"Processor"} -> {"output_handler"}} -> {"templatelist"});

        my $templatetemp;
        foreach my $template (@templates) {
            $templatetemp .= "<option value=\"$template\"";
            # select the default template by... well, default.
            $templatetemp .= ' selected="selected"' if($template eq $wiki -> {$wiki -> {"Processor"} -> {"output_handler"}} -> {"templates"});
            $templatetemp .= ">$template";
            # And explicitly mark it as the default, too.
            $templatetemp .= ' (default)' if($template eq $wiki -> {$wiki -> {"Processor"} -> {"output_handler"}} -> {"templates"});
            $templatetemp .= "</option>\n";
        }

        $templateblock = $sysvars -> {"template"} -> load_template("webui/template_block.tem", {"***templatelist***" => $templatetemp,
                                                                                                "***course***"       => $subcourse -> {"***course***"},
                                                                                                "***lccourse***"     => $subcourse -> {"***lccourse***"}});
    }

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("COURSE_TITLE", $subcourse);
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("COURSE_TITLE", $subcourse),
                                                          $error ? "warn" : $stages -> [STAGE_COURSE] -> {"icon"},
                                                          $stages, STAGE_COURSE,
                                                          $sysvars -> {"template"} -> replace_langvar("COURSE_LONGDESC", $subcourse),
                                                          $sysvars -> {"template"} -> load_template("webui/stage2form.tem", {"***error***"    => $error,
                                                                                                                             "***courses***"  => $courselist,
                                                                                                                             "***template***" => $templateblock,
                                                                                                                             "***course***"   => $subcourse -> {"***course***"},
                                                                                                                             "***lccourse***" => $subcourse -> {"***lccourse***"},
                                                                                                                             "***cpname***"   => $wiki -> {"WebUI"} -> {"course_list"},
                                                                                                                             "***cpurl***"    => $wiki -> {"WebUI"} -> {"course_url"}}));
    return ($title, $message);
}


## @fn @ do_stage2_course($sysvars, $wikiconfig)
# Determine whether the course selected for stage 2 is valid. If it is not, this returns
# stage 2 again with an error message, otherwise it returns undefs.
#
# @param sysvars    A reference to a hash containing database, session, and settings objects.
# @param wikiconfig A reference to the wiki's configuration object.
# @return undef on success, otherwise an array of two elements: the page title, and the
#         message box to show to the user.
sub do_stage2_course {
    my $sysvars    = shift;
    my $wikiconfig = shift;

    # Precalculate these to avoid duplication later...
    my $subcourse = {"***course***"   => ($wikiconfig -> {"wiki2course"} -> {"course_page"} || "Course"),
                     "***lccourse***" => lc($wikiconfig -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Has the user selected a course?
    my $selected = $sysvars -> {"cgi"} -> param("course");
    if($selected) {
        # Get the list of courses...
        my $courses = $sysvars -> {"wiki"} -> get_wiki_courses($wikiconfig);

        # Is the selected course in the list?
        if($courses -> {$selected}) {
            # Course is good, store it
            $sysvars -> {"sess_supp"} -> set_sess_course($selected);

            # Get the filters for this course
            my $filterlist = $sysvars -> {"wiki"} -> get_course_filters($wikiconfig, $selected);
            if($filterlist) {
                # split the filters up
                my @filters = split(/,/, $filterlist);

                # And enhashinate
                my %filterhash = map { $_,1 } @filters;

                # Now go through each of the filters set by the user and, if it appears in the
                # hash, we can add it to a temporary array
                my @setfilter;
                my @cgifilters = $sysvars -> {"cgi"} -> param('filters');
                foreach my $filter (@cgifilters) {
                    my ($safefilter) = $filter =~ /^(\w+)$/; # Ensure that we're only looking at alphanumerics

                    next if(!$safefilter); # And skip anything that didn't pass

                    # Store the filter if it is valid
                    push(@setfilter, $safefilter) if($filterhash{$safefilter});
                }

                $sysvars -> {"sess_supp"} -> set_sess_filters(join(",", @setfilter));

            # if we have no filters for the course, forcibly remove any previously set filters
            } else {
                $sysvars -> {"sess_supp"} -> set_sess_filters("");
            }

            # are there any template options available for this wiki?
            if($wikiconfig -> {$wikiconfig -> {"Processor"} -> {"output_handler"}} -> {"templatelist"}) {
                # Split the list of templates up ready for the validator
                my @templates = split(/,/, $wikiconfig -> {$wikiconfig -> {"Processor"} -> {"output_handler"}} -> {"templatelist"});

                # has the user selected a template?
                my ($template, $error) = $sysvars -> {"validator"} -> validate_options("templates", {"required" => 0,
                                                                                                     "default"  => $wikiconfig -> {$wikiconfig -> {"Processor"} -> {"output_handler"}} -> {"templates"},
                                                                                                     "source"   => \@templates,
                                                                                                     "nicename" => $sysvars -> {"template"} -> replace_langvar("COURSE_TEMPLATE")});
                # If we have no error, store the template name
                if(!$error) {
                    $sysvars -> {"sess_supp"} -> set_sess_templates($template);
                } else { # if(!$error)
                    # User selected a non-existent template
                    return build_stage2_course($sysvars,  $sysvars -> {"template"} -> replace_langvar("COURSE_ERR_BADCOURSE", $subcourse));
                }
            }

            # Work out the verbosity controls, and store them
            # Do not use the values set directly, as they can't be trusted - just see whether they are set
            my $verb_export  = (defined($sysvars -> {"cgi"} -> param("expverb")) && $sysvars -> {"cgi"} -> param("expverb"));
            my $verb_process = (defined($sysvars -> {"cgi"} -> param("procverb")) && $sysvars -> {"cgi"} -> param("procverb"));

            $sysvars -> {"sess_supp"} -> set_sess_verbosity($verb_export, $verb_process);

            # return sweet nothings, as all is well.
            return (undef, undef);

        } else { # if($courses -> {$selected})
            # User has selected a non-existent course...
            return build_stage2_course($sysvars,  $sysvars -> {"template"} -> replace_langvar("COURSE_ERR_BADCOURSE", $subcourse));
        }
    } else { # if($selected)
        # User has not selected a course...
        return build_stage2_course($sysvars,  $sysvars -> {"template"} -> replace_langvar("COURSE_ERR_NOCOURSE", $subcourse));
    }

    return undef;
}


## @fn $ build_stage3_export($sysvars, $error)
# Generate the content for the export stage of the wizard. This will, if needed, check that
# the user has selected an appropriate course, and then lanuch the wiki2course script in
# the background to fetch the data from the wiki before sending back the status form to the
# user.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @param error    An optional error message to display to the user.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage3_export {
    my $sysvars  = shift;
    my $error    = shift;

    # We need to get the wiki's information regardless of anything else, so get the name first...
    my ($config_name, $wiki_user) = $sysvars -> {"sess_supp"} -> get_sess_login()
        or return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_FAILWIKI"));

    # Obtain the wiki's configuration
    my $wiki = $sysvars -> {"wiki"} -> get_wiki_config($config_name);

    # did the user submit from course selection?
    if($sysvars -> {"cgi"} -> param("doexport")) {
        # Attempt to verify and store the course
        my @result = do_stage2_course($sysvars, $wiki);
        return @result if($result[0] && $result[1]);
    }

    # We have a course selected, so now we need to start the export. First get the
    # course name for later...
    my $course = $sysvars -> {"sess_supp"} -> get_sess_course();

    # Invoke the exporter if it isn't already running
    launch_exporter($sysvars, $wiki, $config_name, $course) unless(check_exporter($sysvars));

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($wiki -> {"wiki2course"} -> {"course_page"} || "Course"),
                     "***lccourse***" => lc($wiki -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Get the default delay, but override it if verbosity is enabled.
    my $delay = $sysvars -> {"settings"} -> {"config"} -> {"default_ajax_delay"};
    $delay = $sysvars -> {"settings"} -> {"config"} -> {"verbose_export_delay"} if($sysvars -> {"sess_supp"} -> get_sess_verbosity("export"));

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("EXPORT_TITLE", $subcourse);
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("EXPORT_TITLE", $subcourse),
                                                          $error ? "warn" : $stages -> [STAGE_EXPORT] -> {"icon"},
                                                          $stages, STAGE_EXPORT,
                                                          $sysvars -> {"template"} -> replace_langvar("EXPORT_LONGDESC", $subcourse),
                                                          $sysvars -> {"template"} -> load_template("webui/stage3form.tem", {"***error***"    => $error,
                                                                                                                             "***course***"   => $subcourse -> {"***course***"},
                                                                                                                             "***lccourse***" => $subcourse -> {"***lccourse***"},
                                                                                                                             "***delay***"    => $delay}));
    return ($title, $message);
}


## @fn $ build_stage4_process($sysvars, $error)
# Generate the content for the processing stage of the wizard. This will check that the
# wiki2course script has actually finished, and the course data directory exists, and if
# both are true it will launch the processor script in the background before sending back
# the status form to the user.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @param error    An optional error message to display to the user.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage4_process {
    my $sysvars  = shift;
    my $error    = shift;

    # We need to get the wiki's information regardless of anything else, so get the name first...
    my ($config_name, $wiki_user) = $sysvars -> {"sess_supp"} -> get_sess_login()
        or return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_FAILWIKI"));

    # Obtain the wiki's configuration
    my $wiki = $sysvars -> {"wiki"} -> get_wiki_config($config_name);

    # Is the exporter still running? If so, kick the user back to stage 3
    return build_stage3_export($sysvars, $sysvars -> {"template"} -> replace_langvar("PROCESS_EXPORTING"))
        if(check_exporter($sysvars));

    # We have a course selected, so now we need to start the export. First get the
    # course name for later...
    my $course = $sysvars -> {"sess_supp"} -> get_sess_course();

    # Invoke the processor if needed
    launch_processor($sysvars, $config_name) unless(check_processor($sysvars));

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($wiki -> {"wiki2course"} -> {"course_page"} || "Course"),
                     "***lccourse***" => lc($wiki -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Get the default delay, but override it if verbosity is enabled.
    my $delay = $sysvars -> {"settings"} -> {"config"} -> {"default_ajax_delay"};
    $delay = $sysvars -> {"settings"} -> {"config"} -> {"verbose_process_delay"} if($sysvars -> {"sess_supp"} -> get_sess_verbosity("process"));

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("PROCESS_TITLE", $subcourse);
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("PROCESS_TITLE", $subcourse),
                                                          $error ? "warn" : $stages -> [STAGE_PROCESS] -> {"icon"},
                                                          $stages, STAGE_PROCESS,
                                                          $sysvars -> {"template"} -> replace_langvar("PROCESS_LONGDESC", $subcourse),
                                                          $sysvars -> {"template"} -> load_template("webui/stage4form.tem", {"***error***"    => $error,
                                                                                                                             "***course***"   => $subcourse -> {"***course***"},
                                                                                                                             "***lccourse***" => $subcourse -> {"***lccourse***"},
                                                                                                                             "***delay***"    => $delay}));
    return ($title, $message);
}


## @fn $ build_stage5_finish($sysvars)
# Generate the content for the final stage of the wizard. This will check that the
# processor script has actually finished, and the course data directory exists, and if
# both are true it will launch the zip wrapper script in the background before sending back
# the status form to the user.
#
# @param sysvars  A reference to a hash containing database, session, and settings objects.
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub build_stage5_finish {
    my $sysvars  = shift;

    # We need to get the wiki's information regardless of anything else, so get the name first...
    my ($config_name, $wiki_user) = $sysvars -> {"sess_supp"} -> get_sess_login()
        or return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_FAILWIKI"));

    # Obtain the wiki's configuration
    my $wiki = $sysvars -> {"wiki"} -> get_wiki_config($config_name);

    # Is the processor still running? If so, kick the user back to stage 4
    return build_stage4_process($sysvars, $sysvars -> {"template"} -> replace_langvar("FINISH_PROCESSING"))
        if(check_processor($sysvars));

    # We have a course selected, so now we need to start the export. First get the
    # course name for later...
    my $course = $sysvars -> {"sess_supp"} -> get_sess_course();

    # Invoke the wrapper if needed
    launch_zip($sysvars) unless(check_zip($sysvars));

    my $preview  = path_join($sysvars -> {"settings"} -> {"config"} -> {"output_url"},
                             $sysvars -> {"session"} -> {"sessid"},
                             $course, "index.html");
    my $download = path_join($sysvars ->  {"settings"} -> {"config"} -> {"output_url"},
                             $sysvars -> {"session"} -> {"sessid"},
                             $course.".zip");

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($wiki -> {"wiki2course"} -> {"course_page"} || "Course"),
                     "***lccourse***" => lc($wiki -> {"wiki2course"} -> {"course_page"} || "Course")};

    my $timeout = $sysvars -> {"template"} -> humanise_seconds($sysvars -> {"settings"} -> {"config"} -> {"session_length"});

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("FINISH_TITLE", $subcourse);
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("FINISH_TITLE", $subcourse),
                                                          $stages -> [STAGE_FINISH] -> {"icon"},
                                                          $stages, STAGE_FINISH,
                                                          $sysvars -> {"template"} -> replace_langvar("FINISH_LONGDESC", $subcourse),
                                                          $sysvars -> {"template"} -> load_template("webui/stage5form.tem", {"***course***"      => $subcourse -> {"***course***"},
                                                                                                                             "***lccourse***"    => $subcourse -> {"***lccourse***"},
                                                                                                                             "***previewurl***"  => $preview,
                                                                                                                             "***downloadurl***" => $download,
                                                                                                                             "***timeout***"     => $timeout}));
    return ($title, $message);
}


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

# And a logger for... logging stuff
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

# Start doing logging if needed
$logger -> start_log($settings -> {"config"} -> {"logfile"}) if($settings -> {"config"} -> {"logfile"});

# Create a new CGI object to generate page content through
my $out;
if($settings -> {"config"} -> {"compress_output"}) {
    # If compression is enabled, use the gzip compressed cgi...
    $out = CGI::Compress::Gzip -> new();
} else {
    # Otherwise use bog-standard, perhaps the http(s) stack will compress for us
    $out = CGI -> new();
}

# Create the template handler object
my $template = Template -> new(logger => $logger,
                               basedir => path_join($settings -> {"config"} -> {"base"}, "templates"))
    or $logger -> die_log($out -> remote_host(), "Unable to create template handling object: ".$Template::errstr);

# Create something to help out with wiki interaction
my $wiki = WikiSupport -> new(logger   => $logger,
                              cgi      => $out,
                              dbh      => $dbh,
                              settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create wiki support object: ".$WikiSupport::errstr);

# Create or continue a session
my $session = SessionHandler -> new(logger   => $logger,
                                    cgi      => $out,
                                    dbh      => $dbh,
                                    settings => $settings,
                                    auth => Auth -> new(logger   => $logger,
                                                        cgi      => $out,
                                                        dbh      => $dbh,
                                                        settings => $settings,
                                                        appuser  => AppUser -> new(logger   => $logger,
                                                                                   cgi      => $out,
                                                                                   dbh      => $dbh,
                                                                                   settings => $settings)))
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# And the support object to provide webui specific functions
my $sess_support = SessionSupport -> new(logger   => $logger,
                                         cgi      => $out,
                                         dbh      => $dbh,
                                         settings => $settings,
                                         session  => $session)
    or $logger -> die_log($out -> remote_host(), "Unable to create session support object: ".$SessionSupport::errstr);

# We also need a form validator object
my $validators = FormValidators -> new(logger   => $logger,
                                       cgi      => $out,
                                       dbh      => $dbh,
                                       settings => $settings,
                                       session  => $session,
                                       template => $template)
    or $logger -> die_log($out -> remote_host(), "Unable to create form validator object: ".$FormValidators::errstr);


# Generate the page based on the current step
my $content = page_display({"logger"    => $logger,
                            "session"   => $session,
                            "sess_supp" => $sess_support,
                            "template"  => $template,
                            "dbh"       => $dbh,
                            "settings"  => $settings,
                            "cgi"       => $out,
                            "validator" => $validators,
                            "wiki"      => $wiki});

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

