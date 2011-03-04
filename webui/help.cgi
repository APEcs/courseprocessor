#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend, help script. This script provides 
# a means for users to contact the support address while simultaneously
# including vital information in the email.
# 
# @version 1.0.0 (1 March 2011)
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

# System modules
use CGI qw/:standard -utf8/;                   # Ensure that both CGI and the compressed version are loaded with utf8 enabled.
use CGI::Compress::Gzip qw/:standard -utf8/;
use CGI::Carp qw(fatalsToBrowser set_message); # Catch as many fatals as possible and send them to the user as well as stderr
use Cwd;
use DBI;
use Digest;
use Email::MIME;
use Encode;
use File::Copy;
use File::Path qw(make_path);
use HTML::Entities;
use IO::All;
use MIME::Base64;
use Time::HiRes qw(time);

# Custom modules
use ConfigMicro;
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

# Names of the language variables storing stage titles.
my @titlenames = ("WELCOME_TITLE", 
                  "LOGIN_TITLE",
                  "COURSE_TITLE",
                  "EXPORT_TITLE",
                  "PROCESS_TITLE",
                  "FINISH_TITLE");


## @method @ validate_string($sysvars, $param, $settings)
# Determine whether the string in the namedcgi parameter is set, clean it
# up, and apply various tests specified in the settings. The settings are
# stored in a hash, the recognised contents are as below, and all are optional
# unless noted otherwise:
#
# required   - If true, the string must have been given a value in the form.
# default    - The default string to use if the form field is empty. This is not 
#              used if required is set!
# nicename   - The required 'human readable' name of the field to show in errors.
# minlen     - The minimum length of the string.
# maxlen     - The maximum length of the string.
# chartest   - A string containing a regular expression to apply to the string. If this
#              <b>matches the field</b> the validation fails!
# chardesc   - Must be provided if chartest is provided. A description of why matching
#              chartest fails the validation.
# formattest - A string containing a regular expression to apply to the string. If the
#              string <b>does not</b> match the regexp, validation fails.
# formatdesc - Must be provided if formattest is provided. A description of why not
#              matching formattest fails the validation.
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @param param    The name of the cgi parameter to check/
# @param settings A reference to a hash of settings to control the validation 
#                 done to the string.
# @return An array of two values: the first contains the text in the parameter, or
#         as much of it as can be salvaged, while the second contains an error message
#         or undef if the text passes all checks.
sub validate_string {
    my $sysvars  = shift;
    my $param    = shift;
    my $settings = shift;

    # Grab the parameter value, fall back on the default if it hasn't been set.
    my $text = $sysvars -> {"cgi"} -> param($param);

    # Handle the situation where the parameter has not been provided at all
    if(!defined($text) || $text eq '' || (!$text && $settings -> {"nonzero"})) {
        # If the parameter is required, return empty and an error
        if($settings -> {"required"}) {
            return ("", $sysvars -> {"template"} -> replace_langvar("VALIDATE_NOTSET", "", {"***field***" => $settings -> {"nicename"}}));
        # Otherwise fall back on the default.
        } else {
            $text = $settings -> {"default"} || "";
        }
    }
    
    # If there's a test regexp provided, apply it
    my $chartest = $settings -> {"chartest"};
    return ($text, $sysvars -> {"template"} -> replace_langvar("VALIDATE_BADCHARS", "", {"***field***" => $settings -> {"nicename"},
                                                                                         "***desc***"  => $settings -> {"chardesc"}}))
        if($chartest && $text =~ /$chartest/);

    # Is there a format check provided, if so apply it
    my $formattest = $settings -> {"formattest"};
    return ($text, $sysvars -> {"template"} -> replace_langvar("VALIDATE_BADFORMAT", "", {"***field***" => $settings -> {"nicename"},
                                                                                          "***desc***"  => $settings -> {"formatdesc"}}))
        if($formattest && $text !~ /$formattest/);

    # Convert all characters in the string to safe versions
    $text = encode_entities($text);

    # Now trim spaces
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    # Get here and we have /something/ for the parameter. If the maximum length
    # is specified, does the string fit inside it? If not, return as much of the
    # string as is allowed, and an error
    return (substr($text, 0, $settings -> {"maxlen"}), $sysvars -> {"template"} -> replace_langvar("VALIDATE_TOOLONG", "", {"***field***"  => $settings -> {"nicename"},
                                                                                                                            "***maxlen***" => $settings -> {"maxlen"}}))
        if($settings -> {"maxlen"} && length($text) > $settings -> {"maxlen"});

    # Is the string too short (we only need to check if it's required or has content) ? If so, store it and return an error.
    return ($text, $sysvars -> {"template"} -> replace_langvar("VALIDATE_TOOSHORT", "", {"***field***"  => $settings -> {"nicename"},
                                                                                         "***minlen***" => $settings -> {"minlen"}}))
        if(($settings -> {"required"} || length($text)) && $settings -> {"minlen"} && length($text) < $settings -> {"minlen"});

    # Get here and all the tests have been passed or skipped
    return ($text, undef);
}


## @fn $ get_static_data($sysvars, $stage)
# Obtain the data stored against the user's settings and the transformed stage data.
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @param stage    The stage the user was on when they hit "Contact support"
# @return A hash containing the configuration name, wiki username, wiki config, stage, and course
sub get_static_data {
    my $sysvars = shift;
    my $stage   = shift;
    my $data    = { "stage" => $stage };

    # work out the static information for the user - username, wiki, and so on
    # Get the wiki username and configuration names first..
    ($data -> {"config_name"}, $data -> {"wiki_user"}) = $sysvars -> {"sess_supp"} -> get_sess_login();

    # Obtain the wiki's configuration if possible
    $data -> {"wiki"} = $sysvars -> {"wiki"} -> get_wiki_config($data -> {"config_name"}) if($data -> {"config_name"});

    # Set defaults if not...
    $data -> {"wiki"} -> {"WebUI"} -> {"name"} = $sysvars -> {"template"} -> replace_langvar("HELP_ERR_NOWIKI")
        unless($data -> {"config_name"} && $data -> {"wiki"});

    $data -> {"wiki_user"} = $sysvars -> {"template"} -> replace_langvar("HELP_ERR_USERNAME") unless($data -> {"wiki_user"});

    # Get the title for the stage, if the stage set is numeric.
    $data -> {"stagename"} = $sysvars -> {"template"} -> replace_langvar($titlenames[$stage] || "HELP_ERR_NOSTAGE") 
        if($stage =~ /^\d+$/);

    # Get the selected course namespace
    $data -> {"course"} = $sysvars -> {"sess_supp"} -> get_sess_course() || $sysvars -> {"template"} -> replace_langvar("HELP_ERR_NONS");

    return $data;
}


## @fn @ build_help_form($sysvars, $stage, $error, $args)
# Generate the form to send to the user requesting their details and the details of the problem.
# This will build the contents of the page through which the user should detail their problem
# with the course processor web interface. 
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @param stage    The stage the user was on when they hit "Contact support"
# @param error    An error message to send back to the user.
# @param args     A reference to a hash containing any defined variables to show in the form.
# @return Two strings: the title of the page, and the message box containing the contact form.
sub build_help_form {
    my $sysvars = shift;
    my $stage   = shift;
    my $error   = shift;
    my $args    = shift;

    my $static = get_static_data($sysvars, $stage);

    # If we have an error, encapsulate it
    $error = $sysvars -> {"template"} -> load_template("webui/stage_error.tem", {"***error***" => $error})
        if($error);

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($static -> {"wiki"} -> {"wiki2course"} -> {"course_page"} || "Course"), 
                     "***lccourse***" => lc($static -> {"wiki"} -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Spit out the message box with the form...
    return ($sysvars -> {"template"} -> replace_langvar("HELP_TITLE"),
            $sysvars -> {"template"} -> message_box($sysvars -> {"template"} -> replace_langvar("HELP_TITLE"),
                                                    "warn",
                                                    $sysvars -> {"template"} -> replace_langvar("HELP_SUMMARY"),
                                                    $sysvars -> {"template"} -> replace_langvar("HELP_LONGDESC"),
                                                    $sysvars -> {"template"} -> load_template("webui/helpform.tem", {"***error***"      => $error,
                                                                                                                     "***wikiname***"   => $static -> {"wiki"} -> {"WebUI"} -> {"name"},
                                                                                                                     "***username***"   => $static -> {"wiki_user"},
                                                                                                                     "***coursename***" => $static -> {"course"},
                                                                                                                     "***stagename***"  => $static -> {"stagename"},
                                                                                                                     "***stage***"      => $static -> {"stage"},
                                                                                                                     "***course***"     => $subcourse -> {"***course***"},
                                                                                                                     "***lccourse***"   => $subcourse -> {"***lccourse***"},
                                                                                                                     "***name***"       => $args -> {"name"},
                                                                                                                     "***email***"      => $args -> {"email"},
                                                                                                                     "***summary***"    => $args -> {"summary"},
                                                                                                                     "***fullprob***"   => $args -> {"fullprob"}})));
}


## @fn @ build_acknowledge($sysvars)
# Generate the acknowledgment message to send back to the user.
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @return Two strings: the title of the page, and the message box containing the acknowledgment.
sub build_acknowledge {
    my $sysvars = shift;

    # Spit out the message box with the form...
    return ($sysvars -> {"template"} -> replace_langvar("ACK_TITLE"),
            $sysvars -> {"template"} -> message_box($sysvars -> {"template"} -> replace_langvar("ACK_TITLE"),
                                                    "info",
                                                    $sysvars -> {"template"} -> replace_langvar("ACK_SUMMARY"),
                                                    $sysvars -> {"template"} -> replace_langvar("ACK_LONGDESC")));
}


## @fn @ validate_help_form($sysvars)
# Validate the fields submitted by the user from the help form.
#
# @return An array of two values: a reference to a hash of arguments, and a
#         string containing any errors (or undef if all fields are okay)
sub validate_help_form {
    my $sysvars = shift;
    my ($args, $error, $errors) = ({}, "", "");

    # Pull out the name, even though it's not required
    ($args -> {"name"}, $error) = validate_string($sysvars, 'name', {"required" => 0,
                                                                     "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_NAME"),
                                                                     "maxlen"   => 128});
    $errors .= "$error<br />" if($error);

    # Do we have an email specified?
    ($args -> {"email"}, $error) =  validate_string($sysvars, 'email', {"required" => 1,
                                                                        "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_EMAIL"),
                                                                        "maxlen"   => 255});
    $errors .= "$error<br />" if($error);
    
    # IF we have an email, we want to try to validate it...
    if(!$error) {
        # This is a fairly naive check, but there isn't a huge amount more we can do alas.
        if($args -> {'email'} !~ /^[\w\.-]+\@([\w-]+\.)+\w+$/) {
            $errors .= $sysvars -> {"template"} -> replace_langvar("HELP_ERR_BADEMAIL").'<br />';
        }
        
        # Get here and either $errors has had an appropriate error appended to it, or the email is valid and not in use.
        # lowercase the whole email, as we don't need to deal with "...." < address > here
        $args -> {'email'} = lc($args -> {'email'}) if($args -> {'email'});
    }
    
    # The summary is required...
    ($args -> {"summary"}, $error) = validate_string($sysvars, 'summary', {"required" => 1,
                                                                           "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_PROBSUMM"),
                                                                           "maxlen"   => 255});
    $errors .= "$error<br />" if($error);

    # As is the full description
    ($args -> {"fullprob"}, $error) = validate_string($sysvars, 'fullprob', {"required" => 1,
                                                                             "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_FULLPROB")});
    $errors .= "$error<br />" if($error);

    return ($args, $errors);
}


## @fn $ send_help_email($sysvars, $stage, $args)
# Attempt to send a message to the support address with the information the user
# has supplied. This will prepare the email, including zipping up any existing 
# log files, and squirt the lot at sendmail.
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @param stage    The stage the user was on when they hit "Contact support"
# @param args     A reference to a hash containing any defined variables to show in the form.
# @return undef on success, otherwise this returns an error message.  
sub send_help_email {
    my $sysvars = shift;
    my $stage   = shift;
    my $args    = shift;

    # Obtain all the various gubbings about the user...
    my $static = get_static_data($sysvars, $stage);

    # Precalculate some variables to use in templating
    my $subcourse = {"***course***"   => ($static -> {"wiki"} -> {"wiki2course"} -> {"course_page"} || "Course"), 
                     "***lccourse***" => lc($static -> {"wiki"} -> {"wiki2course"} -> {"course_page"} || "Course")};

    # Now work out where the user's logs might be
    my $logbase = untaint_path(path_join($sysvars -> {"settings"} -> {"config"} -> {"work_path"}, $sysvars -> {"session"} -> {"sessid"}));

    my $cwd = getcwd();
    chdir($logbase)
        or die "FATAL: Unable to change into working directory: $!\n";

    # We're in the log directory, zip up any logs we can. Note that, if no log files
    # exist, this could easily generate nothing...
    `$sysvars->{paths}->{zip} -r9 logfiles.zip *.log`;
    
    # Okay, now we need to create the text part of the email including the user's problem
    # (if the user is the problem, we don't attach them to the email. Thankfully.)
    my @parts;
    my $part = Email::MIME -> create(attributes => { content_type => "text/plain",
                                                     disposition  => "attachment",
                                                     charset      => "US-ASCII" 
                                                   },
                                     body       => $sysvars -> {"template"} -> load_template("email/help.tem", {"***wikiname***"   => $static -> {"wiki"} -> {"WebUI"} -> {"name"},
                                                                                                                "***username***"   => $static -> {"wiki_user"},
                                                                                                                "***coursename***" => $static -> {"course"},
                                                                                                                "***stagename***"  => $static -> {"stagename"},
                                                                                                                "***stage***"      => $static -> {"stage"},
                                                                                                                "***course***"     => $subcourse -> {"***course***"},
                                                                                                                "***lccourse***"   => $subcourse -> {"***lccourse***"},
                                                                                                                "***name***"       => $args -> {"name"},
                                                                                                                "***email***"      => $args -> {"email"},
                                                                                                                "***summary***"    => $args -> {"summary"},
                                                                                                                "***fullprob***"   => $args -> {"fullprob"}}));
    push(@parts, $part);

    # If we have a log zipfile, we want to attach it as well.
    if(-f "logfiles.zip") {
        $part = Email::MIME -> create(attributes => { content_type => "application/zip",
                                                      disposition  => "attachment",
                                                      name         => "logfiles.zip",
                                                      encoding     => "base64"
                                                   },
                                      body       => io("logfiles.zip") -> all);
        push(@parts, $part);
    }

    # Make the overall email...
    my $email = Email::MIME -> create(header => [ From    => $sysvars -> {"settings"} -> {"config"} -> {"system_email"},
                                                  To      => $sysvars -> {"settings"} -> {"config"} -> {"help_email"},
                                                  Subject => $args -> {"summary"}
                                                ],
                                      parts  => \@parts);
    
    # And send it
    return $sysvars -> {"template"} -> send_email_sendmail($email);
}



# =============================================================================
#  Core page code and dispatcher

## @fn $ page_display($sysvars)
# Generate the contents of the page based on whether the user has filled in the
# help request form or not..
#
# @param sysvars A reference to a hash containing references to the template, 
#                database, settings, and cgi objects.
# @return A string containing the page to display.
sub page_display {
    my $sysvars = shift;
    my ($title, $body) = ("", "");

    # Get the current stage, and make it unknown if there's no stage defined
    my $stage = is_defined_numeric($sysvars -> {"cgi"}, "stage");
    $stage = $sysvars -> {"template"} -> replace_langvar("HELP_ERR_NOSTAGE") if(!defined($stage));

    # Did the user submit?
    if($sysvars -> {"cgi"} -> param("dohelp")) {
        # Determine whether the form contents are valid
        my ($args, $errors) = validate_help_form($sysvars);
        
        # No errors? The form is valid, so dispatch the email and acknowledge the submission.
        if(!$errors) {
            my $errors = send_help_email($sysvars, $stage, $args);

            # If the mail was sent without problems, send the ack page...
            if(!$errors) {
                ($title, $body) = build_acknowledge($sysvars);

            # otherwise send back the form with the errors in it
            } else {
                ($title, $body) = build_help_form($sysvars, $stage, $errors, $args);
            }

        # Form contained bad data, send back the form with errors...
        } else {
            ($title, $body) = build_help_form($sysvars, $stage, $errors, $args);
        }

    # User did not submit, so just send the empty form back...
    } else {
        ($title, $body) = build_help_form($sysvars, $stage);
    }
   
    return $sysvars -> {"template"} -> load_template("page.tem", 
                                                     { "***title***"     => $title,
                                                       "***extrahead***" => "",
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
my $template = Template -> new(basedir => path_join($settings -> {"config"} -> {"base"}, "templates"),
                               mailcmd => "/usr/sbin/sendmail -t -f ".$settings -> {"config"} -> {"system_email"})
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
                                    settings => $settings)
    or $logger -> die_log($out -> remote_host(), "Unable to create session object: ".$SessionHandler::errstr);

# And the support object to provide webui specific functions
my $sess_support = SessionSupport -> new(logger   => $logger,
                                         cgi      => $out, 
                                         dbh      => $dbh,
                                         settings => $settings,
                                         session  => $session)
    or $logger -> die_log($out -> remote_host(), "Unable to create session support object: ".$SessionSupport::errstr);

# Generate the page based on the current step
my $content = page_display({"logger"    => $logger,
                            "session"   => $session,
                            "sess_supp" => $sess_support,
                            "template"  => $template,
                            "dbh"       => $dbh,
                            "settings"  => $settings,
                            "cgi"       => $out,
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

