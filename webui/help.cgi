#!/usr/bin/perl -wT

## @file
# APEcs course processor web frontend, help script. This script provides
# a means for users to contact the support address while simultaneously
# including vital information in the email.
#
# @version 1.0.2 (9 March 2011)
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

# Names of the language variables storing stage titles.
my @titlenames = ("WELCOME_TITLE",
                  "LOGIN_TITLE",
                  "COURSE_TITLE",
                  "EXPORT_TITLE",
                  "PROCESS_TITLE",
                  "FINISH_TITLE");


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
    ($args -> {"name"}, $error) = $sysvars -> {"validator"} -> validate_string('name', {"required" => 0,
                                                                                        "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_NAME"),
                                                                                        "maxlen"   => 128});
    $errors .= "$error<br />" if($error);

    # Do we have an email specified?
    ($args -> {"email"}, $error) =  $sysvars -> {"validator"} -> validate_string('email', {"required" => 1,
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
    ($args -> {"summary"}, $error) = $sysvars -> {"validator"} -> validate_string('summary', {"required" => 1,
                                                                                              "nicename" => $sysvars -> {"template"} -> replace_langvar("HELP_PROBSUMM"),
                                                                                              "maxlen"   => 255});
    $errors .= "$error<br />" if($error);

    # As is the full description
    ($args -> {"fullprob"}, $error) = $sysvars -> {"validator"} -> validate_string('fullprob', {"required" => 1,
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

    # Only bother trying to zip up logs if the session has a working directory
    if(-d $logbase) {
        chdir($logbase)
            or die "FATAL: Unable to change into working directory: $!\n";

        # We're in the log directory, zip up any logs we can. Note that, if no log files
        # exist, this could easily generate nothing...

        # Delete any old zip file, just in case
        unlink("logfiles.zip") if(-f "logfiles.zip");

        # And make the new one.
        `$sysvars->{settings}->{paths}->{zip} -r9 logfiles.zip *.log`;
    }

    # Okay, now we need to create the text part of the email including the user's problem
    # (if the user is the problem, we don't attach them to the email. Thankfully.)
    my @parts;
    my $part = Email::MIME -> create(attributes => { content_type => "text/plain",
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

    # If we have a log zipfile, we want to attach it as well. Use an absolute path for the
    # check, but if the file exists then the current working directory is the session work
    # directory anyway, so we can use a relative path when loading the data...
    if(-f path_join($logbase, "logfiles.zip")) {
        $part = Email::MIME -> create(attributes => { content_type => "application/zip",
                                                      disposition  => "attachment",
                                                      name         => "logfiles.zip",
                                                      encoding     => "base64"
                                                   },
                                      body       => io("logfiles.zip") -> all);
        push(@parts, $part);
    }

    # Restore the old directory if needed (may do nothing)
    chdir(untaint_path($cwd));

    # Make the overall email...
    my $email = Email::MIME -> create(header => [ From    => $args -> {"email"},
                                                  To      => $sysvars -> {"settings"} -> {"config"} -> {"help_email"},
                                                  Subject => $args -> {"summary"}
                                                ],
                                      parts  => \@parts);

    # And send it
    return $sysvars -> {"template"} -> send_email_sendmail($email -> as_string());
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
my $template = Template -> new(logger => $logger,
                               basedir => path_join($settings -> {"config"} -> {"base"}, "templates"),
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

