## @file
# This file contains the implementation of a session support class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 0.1
# @date    1 Mar 2011
# @copy    2011, Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# The SessionSupport class provides various functions specifically
# required by the course processor web ui.
package SessionSupport;

require 5.005;
use strict;

# Globals...
use vars qw{$VERSION $errstr};

BEGIN {
	$VERSION = 0.1;
	$errstr  = '';
}

# ============================================================================
#  Constructor

## @cmethod SessionSupport new(@args)
# Create a new SessionSupport object, and start session handling.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new SessionSupport object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $obj     = {
        cgi          => undef,
        dbh          => undef,
        settings     => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($obj -> {"cgi"});
    return set_error("dbh object not set") unless($obj -> {"dbh"});
    return set_error("settings object not set") unless($obj -> {"settings"});

    return bless $obj, $class;
}


# ============================================================================
#  Support functions

## @fn $ clear_sess_login()
# Clear the marker indicating that the current session has logged into the wiki
# successfully, and remove the wiki selection.
#
# @param self A reference to a hash containing database, session, and settings objects.
# @return undef on success, otherwise an error message.
sub clear_sess_login {
    my $self = shift;

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # simple query, really...
    my $nukedata = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                  " WHERE `id` = ? AND `key` LIKE ?");
    $nukedata -> execute($session -> {"id"}, "logged_in")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session login flag: ".$self -> {"dbh"} -> errstr);

    $nukedata -> execute($session -> {"id"}, "wiki_config")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session wiki setup: ".$self -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ set_sess_login($wiki_config)
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
# @param self A reference to a hash containing database, session, and settings objects.
# @param wiki_config The name of the wiki the user has selected and logged into.
# @return undef on success, otherwise an error message.
sub set_sess_login {
    my $self     = shift;
    my $wiki_config = shift;

    # Make sure we have no existing data
    clear_sess_login($self);

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # Only one query needed for both operations
    my $setdata = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " VALUES(?, ?, ?)");

    $setdata -> execute($session -> {"id"}, "logged_in", "1")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session login flag: ".$self -> {"dbh"} -> errstr);

    $setdata -> execute($session -> {"id"}, "wiki_config", $wiki_config)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session wiki setup: ".$self -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ get_sess_login()
# Obtain the user's wiki login status, and the name of the wiki they logged into if
# they have done so.
#
# @param self A reference to a hash containing database, session, and settings objects.
# @return The name of the wiki config for the wiki the user has logged into, or undef
#         if the user has not logged in yet.
sub get_sess_login {
    my $self = shift;

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # Ask the database for the user's settings
    my $getdata = $self -> {"dbh"} -> prepare("SELECT value FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " WHERE `id` = ? AND `key` LIKE ?");

    # First, have we logged in? If not, return undef
    $getdata -> execute($session -> {"id"}, "logged_in")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session login variable: ".$self -> {"dbh"} -> errstr);
    
    my $data = $getdata -> fetchrow_arrayref();
    return 0 unless($data && $data -> [0]);

    # We're logged in, get the wiki config name!
    $getdata -> execute($session -> {"id"}, "wiki_config")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session wiki variable: ".$self -> {"dbh"} -> errstr);

    $data = $getdata -> fetchrow_arrayref();
    return $data -> [0] if($data && $data -> [0]);

    # Get here and we have no wiki config selected, fall over. This should not happen!
    return undef;
}


## @fn $ set_sess_course($course)
# Set the course the selected by the user in their session data for later use.
#
# @param self A reference to a hash containing database, session, and settings objects.
# @param course  The name of the course namespace the user has chosen to export.
# @return undef on success, otherwise an error message.
sub set_sess_course {
    my $self = shift;
    my $course  = shift;

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # delete any existing course selection
    my $nukecourse = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                    " WHERE `id` = ? AND `key` LIKE 'course'");
    $nukecourse -> execute($session -> {"id"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session course selection: ".$self -> {"dbh"} -> errstr);

    # Insert the new value
    my $newcourse = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                   " VALUES(?, 'course', ?)");
    $newcourse -> execute($session -> {"id"}, $course)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session course selection: ".$self -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ get_sess_course()
# Obtain the name of the course the user has selected to export.
#
# @param self A reference to a hash containing database, session, and settings objects.
# @return The name of the course selected by the user, or undef if one has not been selected.
sub get_sess_course {
    my $self = shift;

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # Ask the database for the user's settings
    my $getdata = $self -> {"dbh"} -> prepare("SELECT value FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " WHERE `id` = ? AND `key` LIKE 'course'");
    $getdata -> execute($session -> {"id"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session course variable: ".$self -> {"dbh"} -> errstr);

    my $data = $getdata -> fetchrow_arrayref();
    return $data -> [0] if($data && $data -> [0]);

    return undef;
}


## @fn $ set_sess_verbosity($verb_export, $verb_process)
# Set the export and processor verbosity levels for the session. 
#
# @param self      A reference to a hash containing database, session, and settings objects.
# @param verb_export  The verbosity of exporting, should be 0 or 1.
# @param verb_process The verbosity of processing, should be 0 or 1.
# @return undef on success, otherwise an error message.
sub set_sess_verbosity {
    my $self      = shift;
    my $verb_export  = shift;
    my $verb_process = shift;

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # delete any existing verbosities selection
    my $nukeverbosity = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                    " WHERE `id` = ? AND `key` LIKE ?");
    $nukeverbosity -> execute($session -> {"id"}, "verb_export")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session export verbosity selection: ".$self -> {"dbh"} -> errstr);

    $nukeverbosity -> execute($session -> {"id"}, "verb_process")
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to remove session process verbosity selection: ".$self -> {"dbh"} -> errstr);

    # Insert the new value
    my $newverbosity = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                      " VALUES(?, ?, ?)");
    $newverbosity -> execute($session -> {"id"}, "verb_export", $verb_export)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session export verbosity selection: ".$self -> {"dbh"} -> errstr);

    $newverbosity -> execute($session -> {"id"}, "verb_process", $verb_process)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to set session export verbosity selection: ".$self -> {"dbh"} -> errstr);

    return undef;
}


## @fn $ get_sess_verbosity($mode)
# Obtain the value for the specified verbosity type. The secodn argument must be "export" or
# "process", or the function will die with an error.
#
# @param self A reference to a hash containing database, session, and settings objects.
# @param mode    The job mode, should be either "export" or "process".
# @return The verbosity level set for the specified mode.
sub get_sess_verbosity {
    my $self = shift;
    my $mode    = shift;

    $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Illegal mode passed to get_sess_verbosity()") if($mode ne "export" && $mode ne "process");

    # Obtain the session record
    my $session = $self -> {"session"} -> get_session($self -> {"session"} -> {"sessid"});

    # Ask the database for the user's settings
    my $getdata = $self -> {"dbh"} -> prepare("SELECT value FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                 " WHERE `id` = ? AND `key` LIKE ?");
    $getdata -> execute($session -> {"id"}, "verb_".$mode)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "index.cgi: Unable to obtain session course variable: ".$self -> {"dbh"} -> errstr);

    my $data = $getdata -> fetchrow_arrayref();
    return $data -> [0] if($data && $data -> [0]);

    return undef;
}


## @fn $ set_error($error)
# Set the error string to the specified value. This updates the class error
# string and returns undef.
#
# @param error The message to set in the error string
# @return undef, always.
sub set_error {
    $errstr = shift;

    return undef;
}

1;
