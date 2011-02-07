#!/usr/bin/perl -wT

use strict;
use lib qw(../modules);
#use utf8;

# System modules
use CGI;
use CGI::Compress::Gzip qw/:standard -utf8/;   # Enabling utf8 here is kinda risky, with the file uploads, but eeegh
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use DBI;
use Digest;
use Encode;
use File::Copy;
use HTML::Entities;
use MediaWiki::API;
use MIME::Base64;
use Time::HiRes qw(time);

# Custom modules
use CookieHelper qw(get_cookies set_cookies);
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
                 "hasback"  => 0,
                 "func"     => \&build_stage4_process },
               { "active"   => "templates/default/images/stages/finish_active.png",
                 "inactive" => "templates/default/images/stages/finish_inactive.png",
                 "passed"   => "templates/default/images/stages/finish_passed.png",
                 "width"    => 80,
                 "height"   => 40,
                 "alt"      => "Finish",
                 "icon"     => "finish",
                 "hasback"  => 0,
                 "func"     => \&build_stage5_finish } ];


# =============================================================================
#  Database interaction

## @fn $ clear_wiki_login($sysvars)
# Clear the marker indicating that the current session has logged into the wiki
# successfully, and remove the wiki selection.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return undef on success, otherwise an error message.
sub clear_wiki_login {
    my $sysvars = shift;

    # Obtain the session record
    my $session = $sysvars -> {"session"} -> get_session($sysvars -> {"session"} -> {"sessid"});

    # simple query, really...
    my $nukedata = $sysvars -> {"dbh"} -> prepare("DELETE FROM ".$sysvars -> {"settings"} -> {"database"} -> {"session_data"}.
                                                  " WHERE `id` = ? AND `key` LIKE ?");
    $nukedata -> execute($session -> {"id"}, "logged_in")
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session login flag: ".$sysvars -> {"dbh"} -> errstr);

    $nukedata -> execute($session -> {"id"}, "wiki_config")
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session wiki setup: ".$sysvars -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ set_wiki_login($sysvars, $wiki_config)
# Mark the user for this session as logged in, and store the wiki config that
# they have selected. Note that this <i>does not</i> store any user login info:
# the only time the user's own login info is present is during the step to 
# validate that the user is allowed to use the wiki. Once that is checked,
# this is called to say that the user has logged in successfully, at that point
# the bot user specified in the wiki config takes over the export process. This
# is a means to avoid having to store the user's password in plain text for
# later invocations of wiki2course.pl and processor.pl, instead a special 
# read-only user is used once a user has proved they have access.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @param wiki_config The name of the wiki the user has selected and logged into.
# @return undef on success, otherwise an error message.
sub set_wiki_login {
    my $sysvars     = shift;
    my $wiki_config = shift;

    # Make sure we have no existing data
    clear_wiki_login($sysvars);

    # Obtain the session record
    my $session = $sysvars -> {"session"} -> get_session($sysvars -> {"session"} -> {"sessid"});

    # Only one query needed for both operations
    my $setdata = $sysvars -> {"dbh"} -> prepare("INSERT INTO ".$sysvars -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " VALUES(?, ?, ?)");

    $setdata -> execute($session -> {"id"}, "logged_in", "1")
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session login flag: ".$sysvars -> {"dbh"} -> errstr);

    $setdata -> execute($session -> {"id"}, "wiki_config", $wiki_config)
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session wiki setup: ".$sysvars -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ get_wiki_login($sysvars)
# Obtain the user's wiki login status, and the name of the wiki they logged into if
# they have done so.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return The name of the wiki config for the wiki the user has logged into, or undef
#         if the user has not logged in yet.
sub get_wiki_login {
    my $sysvars = shift;

    # Obtain the session record
    my $session = $sysvars -> {"session"} -> get_session($sysvars -> {"session"} -> {"sessid"});

    # Ask the database for the user's settings
    my $getdata = $sysvars -> {"dbh"} -> prepare("SELECT value FROM ".$sysvars -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " WHERE `id` = ? AND `key` LIKE ?");

    # First, have we logged in? If not, return undef
    $getdata -> execute($session -> {"id"}, "logged_in")
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session login variable: ".$sysvars -> {"dbh"} -> errstr);
    
    my $data = $getdata -> fetchrow_arrayref();
    return 0 unless($data && $data -> [0]);

    # We're logged in, get the wiki config name!
    $getdata -> execute($session -> {"id"}, "wiki_config")
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session wiki variable: ".$sysvars -> {"dbh"} -> errstr);

    $data = $getdata -> fetchrow_arrayref();
    return $data -> [0] if($data && $data -> [0]);

    # Get here and we have no wiki config selected, fall over. This should not happen!
    return undef;
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
    my @courselist = $coursepage -> {"*"} =~ /\[\[(.*?)\]\]/;

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

## @fn $ get_wikiconfig_hash($sysvars)
# Obtain a hash containing the processor configurations for the wikis the web ui
# knows how to talk to. The hash is keyed off the configuration filename, while
# the value of each is a ConfigMicro object.
#
# @param sysvars A reference to a hash containing database, session, and settings objects.
# @return A hash of configurations.
sub get_wikiconfig_hash {
    my $sysvars    = shift;
    my $confighash = {};

    # open the wiki configuration directory...
    opendir(CONFDIR, $sysvars -> {"settings"} -> {"config"} -> {"wikiconfigs"})
        or $sysvars -> {"logger"} -> die_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration dir: ".$sysvars -> {"dbh"} -> errstr);

    while(my $entry = readdir(CONFDIR)) {
        # Skip anything that is obviously not config-like
        next unless($entry =~ /.config$/);

        # Try to load the config. This may well fail, but it's not fatal if it does...
        my $config = ConfigMicro -> new(path_join($sysvars -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $entry))
            or $sysvars -> {"logger"} -> warn_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration: ".$ConfigMicro::errstr);

        # If we actually have a config, store it
        $confighash -> {$entry} = $config if($config);
    }

    closedir(CONFDIR);

    return $confighash;
}


## @fn $ get_wiki_config($sysvars, $config_name)
# Load the configuration file for the specified wiki. This will load the config
# from the wiki configuration directory and return a reference to it.
#
# @param sysvars     A reference to a hash containing database, session, and settings objects.
# @param config_name The name of the wiki config to load. Should not contain any path!
# @return A reference to the wiki config object, or undef on failure.
sub get_wiki_config {
    my $sysvars     = shift;
    my $config_name = shift;

    # Try to load the config. 
    my $config = ConfigMicro -> new(path_join($sysvars -> {"settings"} -> {"config"} -> {"wikiconfigs"}, $config_name))
        or $sysvars -> {"logger"} -> warn_log($sysvars -> {"cgi"} -> remote_host(), "index.cgi: Unable to open wiki configuration $config_name: ".$ConfigMicro::errstr);

    return $config;
}


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
        $options .= ">".$wikihash -> {$wiki} -> {"WebUI"} -> {"name"}." (".$wikihash -> {$wiki} -> {"WebUI"} -> {"wiki_url"}.")</option>\n";
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
        $options .= ' selected="selected"' if($default && $ns eq $default);
        $options .= ">".$coursehash -> {$ns}."</option>\n";
    }

    return $sysvars -> {"template"} -> load_template("webui/course_select.tem", {"***entries***" => $options});
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
    clear_wiki_login($sysvars);

    # Get a hash of wikis we know how to talk to
    my $wikis = get_wikiconfig_hash($sysvars);

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
        my $wikis = get_wikiconfig_hash($sysvars);

        # Is the wiki valid?
        if($setwiki =~ /^\w+\.config$/ && $wikis -> {$setwiki}) {
            # Do we have login details? If so, try to validate them...
            if($sysvars -> {"cgi"} -> param("username") && $sysvars -> {"cgi"} -> param("password")) {
                if(check_wiki_login($sysvars -> {"cgi"} -> param("username"), 
                                    $sysvars -> {"cgi"} -> param("password"),
                                    $wikis -> {$setwiki})) {
                    set_wiki_login($sysvars, $setwiki);
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
    }

    # If the user has logged in successfully, obtain a list of courses from the wiki.
    my $config_name = get_wiki_login($sysvars)
        or return build_stage1_login($sysvars, $sysvars -> {"template"} -> replace_langvar("LOGIN_ERR_FAILWIKI"));

    # Obtain the wiki's configuration
    my $wiki = get_wiki_config($sysvars, $config_name);

    # Get the list of courses
    my $courses = get_wiki_courses($wiki);
    
    # And convert to a select box
    my $courselist = make_course_select($sysvars, $courses, $sysvars -> {"cgi"} -> param("course"));
    
    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($wiki -> {"wiki2config"} -> {"course_page"} || "Course"), 
                     "***lccourse***" => lc($wiki -> {"wiki2config"} -> {"course_page"} || "Course")};

    # Now generate the title, message.
    my $title    = $sysvars -> {"template"} -> replace_langvar("COURSE_TITLE", $subcourse);
    my $message  = $sysvars -> {"template"} -> wizard_box($sysvars -> {"template"} -> replace_langvar("COURSE_TITLE", $subcourse),
                                                          $error ? "warn" : $stages -> [STAGE_COURSE] -> {"icon"},
                                                          $stages, STAGE_COURSE,
                                                          $sysvars -> {"template"} -> replace_langvar("COURSE_LONGDESC", $subcourse),
                                                          $sysvars -> {"template"} -> load_template("webui/stage2form.tem", {"***error***"   => $error,
                                                                                                                             "***courses***" => $courselist,
                                                                                                                             "***course***"  => $subcourse -> {"***course***"}}));
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
my $template = Template -> new(basedir => path_join($settings -> {"config"} -> {"base"}, "templates"))
    or $logger -> die_log($out -> remote_host(), "Unable to create template handling object: ".$Template::errstr);

# Create or continue a session
my $session = SessionHandler -> new(logger   => $logger,
                                    cgi      => $out, 
                                    dbh      => $dbh,
                                    template => $template,
                                    settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

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

