## @file
# This file contains the implementation of a session creation/handling class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 0.3
# @date    24 Jan 2011
# @copy    2009-2011, Chris Page &lt;chris@starforge.co.uk&gt;
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
# The SessionHandler class provides cookie-based session facilities for 
# maintaining user state over http transactions. This code provides session 
# verification, and takes some steps towards ensuring security against 
# cookie hijacking, but as with any cookie based auth system there is 
# the potential for security issues (use https whenever possible!)
#
# This code is heavily based around the session code used by phpBB3, with
# features removed or added to fit the different requirements of the ORB,
# starforge site, etc
package SessionHandler;

require 5.005;
use strict;

# Standard module imports
use DBI;
use Digest::MD5 qw(md5_hex);
use Compress::Bzip2;
use MIME::Base64;
use String::Urandom;

use Data::Dumper;

# Globals...
use vars qw{$VERSION $errstr};

BEGIN {
	$VERSION = 0.3;
	$errstr  = '';
}

# ============================================================================
#  Constructor

## @cmethod SessionHandler new(@args)
# Create a new SessionHandler object, and start session handling.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new SessionHandler object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        cgi          => undef,
        dbh          => undef,
        template     => undef,
        settings     => undef,
        session_time => 0,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("template object not set") unless($self -> {"template"});
    return set_error("settings object not set") unless($self -> {"settings"});

    # Bless class so we canuse it properly
    $self = bless $self, $class;

    # cleanup if necessary
    return undef
        unless($self -> session_cleanup());

    # Determine the name of the cookie, and fall over if it isn't available for some reason
    my $cookiebase = $self -> {"settings"} -> {"config"} -> {"cookie_name"}
        or return set_error("Unable to determine sessioncookie name");

    # Now try to obtain a session id - start by looking at the cookies
    $self -> {"sessid"}   = $self -> {"cgi"} -> cookie($cookiebase."_sid"); # The session id cookie itself

    # If we don't have a session id now, try to pull it from the query string
    $self -> {"sessid"} = $self -> {"cgi"} -> param("sid") if(!$self -> {"sessid"});
     
    # If we have a session id, we need to check it
    if($self -> {"sessid"}) {
        # Try to get the session...
        my $session = $self -> get_session($self -> {"sessid"});

        # Do we have a valid session?
        if($session) {
            $self -> {"session_time"} = $session -> {"session_time"};

            # Is the user accessing the site from the same(-ish) IP address?
            if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
                # Has the session expired?
                if(!$self -> session_expired($session)) {
                    # The session is valid, and can be touched.
                    $self -> touch_session($session);
 
                    return $self;
                } # if(!$self -> session_expired($session)) { 
            } # if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
        } # if($session) {
    } # if($sessid) {

    # Get here, and we don't have a session at all, so make one.
    return $self -> create_session();
}


## @method $ create_session()
# Create a new session.
#
# @return true if the session was created, undef otherwise.
sub create_session {
    my $self = shift;

    # nuke the cookies, it's the only way to be sure
    delete($self -> {"cookies"}) if($self -> {"cookies"});
    
    # get the current time...
    my $now = time();

    # Do we already have a session id? If we do, and it's an anonymous session, we want to nuke it
    if($self -> {"sessid"}) {
        my $killsess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_id = ?");
        $killsess -> execute($self -> {"sessid"})
            or return set_error("Unable to remove anonymous session\nError was: ".$self -> {"dbh"} -> errstr);
    }
    
    # generate a new session id. The md5 of some greater and lesser random stuff will do
    my $urand = String::Urandom -> new();
    $self -> {"sessid"} = md5_hex($now.$ENV{"REMOTE_ADDR"}.$urand -> rand_string());

    # store the time
    $self -> {"session_time"} = $now;

    # create a new session
    my $sessh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                            " VALUES(NULL, ?, ?, ?, ?, 0)");
    $sessh -> execute($self -> {"sessid"},
                      $now,
                      $now,
                      $ENV{"REMOTE_ADDR"})
            or return set_error("Unable to peform session creation\nError was: ".$self -> {"dbh"} -> errstr);

    return $self;
}


## @method $ delete_session()
# Delete the current session, resetting the user's data to anonymous. This will
# remove the user's current session, and any associated autologin key, and then
# generate a new anonymous session for the user.
sub delete_session {
    my $self = shift;

    my $sessdata = $self -> get_session($self -> {"sessid"})
        or return set_error("Unable to locate session data for current session.");

    # Okay, the important part first - nuke the session
    my $nukesess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                               " WHERE id = ?");
    $nukesess -> execute($sessdata -> {"id"})
        or return set_error("Unable to remove session\nError was: ".$self -> {"dbh"} -> errstr);

    $nukesess = $self -> {"dbh"} -> prepare("DELECT FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                            " WHERE id = ?");

    $nukesess -> execute($sessdata -> {"id"})
        or return set_error("Unable to remove session data\nError was: ".$self -> {"dbh"} -> errstr);

    # clear all the session settings internally for safety
    $self -> {"sessid"} = $self -> {"session_time"} = undef;

    # And create a new session (note that create_session should handle deleting the cookie cache!)
    return $self -> create_session();
}


## @method $ encode_querystring($query, $nofix)
# Encode the query string so that it is safe to include it in a hidden input field
# in the login form.
#
# @param query The querystring to encode
# @param nofix If true, this disables the fix needed to make CGI::query_string()'s output usable.
# @return The safely encoded querystring.
sub encode_querystring {
    my $self   = shift;
    my $query  = shift;
    my $nofix  = shift;

    $query =~ s/;/&/g unless($nofix); # fix query_string() return... GRRRRRRR...

    return encode_base64($query, '');
}


## @method $ decode_querystring($query)
# Converts the encoded query string back to standard query string form.
#
# @param query The encoded querystring to decode
# @return The decoded version of the querystring.
sub decode_querystring {
    my $self   = shift;
    my $query  = shift;
    
    # Bomb if we don't have a query, or it is not valid base64
    return "" if(!$query || $query =~ m{[^A-Za-z0-9+/=]});

    return decode_base64($query);
}


## @method $ session_cookies()
# Obtain a reference to an array containing the session cookies.
#
# @return A reference to an array of session cookies.
sub session_cookies {
    my $self = shift;

    # Cache the cookies if needed, calls to create_session should ensure the cache is
    # removed before any changes are made... but this shouldn't really be called before
    # create_session in reality anyway.
    if(!$self -> {"cookies"}) {
        my $sesscookie = $self -> create_session_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_sid', $self -> {"sessid"}, 0);

        $self -> {"cookies"} = [ $sesscookie ];
    }

    return $self -> {"cookies"};
}


## @method $ set_session_data($key, $value)
# Set the value of a data element for the current session. This will store the 
# sepecified key with the associated value in the session data table so that it
# may be used over multiple requests as needed.
#
# @param key   The name of the data to store.
# @param value The value to store.
# @return true on success, undef if an error was encountered.
sub set_session_data {
    my $self  = shift;
    my $key   = shift;
    my $value = shift;

    my $sessdata = $self -> get_session($self -> {"sessid"})
        or return set_error("Unable to locate session data for current session.");

    # Delete any existing data, as it is no longer needed
    my $nukedata = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                               " WHERE id = ? AND key = ?");
    $nukedata -> execute($sessdata -> {"id"}, $key)
        or return set_error("Unable to remove old data for session data '$key'\nError was: ".$self -> {"dbh"} -> errstr);
        
    # Now insert the new data
    my $newdata = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                              " VALUES(?, ?, ?)");
    $newdata -> execute($sessdata -> {"id"}, $key, $value)
        or return set_error("Unable to store data for session data '$key'\nError was: ".$self -> {"dbh"} -> errstr);

    return 1;
}


## @method $ get_session_data($key)
# Get the value of a data element for the current session. This will retrieve
# the value for the sepecified key in the session data table.
#
# @param key   The name of the data to retrieve.
# @return The value stored for the key, or undef if the key is not set.
sub set_session_data {
    my $self  = shift;
    my $key   = shift;

    my $sessdata = $self -> get_session($self -> {"sessid"})
        or return set_error("Unable to locate session data for current session.");

    my $data = $self -> {"dbh"} -> prepare("SELECT value FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                           " WHERE id = ? AND key = ?");
    $data -> execute($sessdata -> {"id"}, $key)
        or return set_error("Unable to obtain session data for '$key'\nError was: ".$self -> {"dbh"} -> errstr);
        
    # Return the data if we have it...
    my $datarow = $data -> fetchrow_arrayref();
    return $datarow -> [0] if($datarow);

    # Return nothing if we don't...
    return set_error("");
}
    


# ==============================================================================
# Theoretically internal stuff


## @method ip_check($userip, $sessip)
# Checks whether the specified IPs match. The degree of match required depends
# on the ip_check setting in the SessionHandler object this is called on: 0 means
# that no checking is done, number between 1 and 4 indicate sections of the 
# dotted decimal IPs are checked (1 = 127., 2 = 127.0, 3 = 127.0.0., etc)
#
# @param userip The IP the user is connecting from.
# @param sessip The IP associated with the session.
# @return True if the IPs match, false if they do not.
sub ip_check {
    my $self   = shift;
    my $userip = shift;
    my $sessip = shift;

    # How may IP address segments should be compared?
    my $iplen = $self -> {"settings"} -> {"config"} -> {'ip_check'};

    # bomb immediately if we aren't checking IPs
    return 1 if($iplen == 0);

    # pull out as much IP as we're interested in
    my ($usercheck) = $userip =~ /((?:\d+.?){$iplen})/;
    my ($sesscheck) = $sessip =~ /((?:\d+.?){$iplen})/;

    # Do the IPs match?
    return $usercheck eq $sesscheck;
}


## @method $ session_cleanup()
# Run garbage collection over the sessions table. This will remove all expired
# sessions.
#
# @return true on successful cleanup (or cleanup not needed), false on error.
sub session_cleanup {
    my $self = shift;

    my $now = time();
    my $timelimit = $now - $self -> {"config"} -> {"config"} -> {"session_length"};

    # We only want to run the garbage collect occasionally
    if($self -> {"settings"} -> {"config"} -> {"lastgc"} < $now - $self -> {"settings"} -> {"config"} -> {"session_gc"}) {
        # Okay, we're due a garbage collect, update the config to reflect that we're doing it
        $self -> {"settings"} -> set_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"}, "lastgc", $now);

        # Delete old session data
        my $nukedata = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_data"}.
                                                   " WHERE id IN (SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                                " WHERE session_time < ?)");
        $nukedata -> execute($timelimit)
            or return set_error("Unable to remove expired session data\nError was: ".$self -> {"dbh"} -> errstr);
        
        # Now delete the sessions themselves
        my $nukesess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_time < ?");
        $nukesess -> execute($timelimit)
            or return set_error("Unable to remove expired sessions\nError was: ".$self -> {"dbh"} -> errstr);
    }

    return 1;
}


## @method $ session_expired($sessdata)
# Determine whether the specified session has expired. Returns true if it has,
# false if it is still valid.
#
# @param $sessdata A reference to a hash containing the session information
# @return true if the session has expired, false otherwise
sub session_expired {
    my $self = shift;
    my $sessdata = shift;

    return 1 if($sessdata -> {"session_time"} < time() - ($self -> {"settings"} -> {"config"} -> {"session_length"} + 60));

    # otherwise, the session is valid
    return 0;
}


## @method $ get_session($sessid)
# Obtain the data for the session with the specified session ID. If there is no 
# session with the specified id in the database, this returns undef, otherwise it
# returns a reference to a hash containing the session data.
#
# @param sessid The ID of the session to search for.
# @return A reference to a hash containing the session data, or undef on error.
sub get_session {
    my $self   = shift;
    my $sessid = shift;

    my $sessh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                            " WHERE session_id = ?");
    $sessh -> execute($sessid)
        or return set_error("Unable to peform session lookup query - ".$self -> {"dbh"} -> errstr);

    return $sessh -> fetchrow_hashref();
}


## @method void touch_session($session)
# Touch the specified session, updating its timestamp to the current time. This
# will only touch the session if it has not been touched in the last minute,
# otherwise this function does nothing.
#
# @param session A reference to a hash containing the session data.
sub touch_session {
    my $self    = shift;
    my $session = shift;

    if(time() - $session -> {"session_time"} > 60) {
        $self -> {"session_time"} = time();

        my $finger = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                 " SET session_time = ?
                                                   WHERE id = ?");
        $finger -> execute($self -> {"session_time"}, $session -> {"id"})
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to touch session. Error was: ".$self -> {"dbh"} -> errstr);
    }
}


## @method $ create_session_cookie($name, $value)
# Creates a cookie that can be sent back to the user's browser to provide session
# information. No expiration is stored (this is a session cookie)
#
# @param name    The name of the cookie to set
# @param value   The value to set for the cookie
# @return A cookie suitable to send to the browser.
sub create_session_cookie {
    my $self    = shift;
    my $name    = shift;
    my $value   = shift;

    return $self -> {"cgi"} -> cookie(-name    => $name,
                                      -value   => $value,
                                      -path    => $self -> {"settings"} -> {"config"} -> {"cookie_path"},
                                      -domain  => $self -> {"settings"} -> {"config"} -> {"cookie_domain"},
                                      -secure  => $self -> {"settings"} -> {"config"} -> {"cookie_secure"});
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
