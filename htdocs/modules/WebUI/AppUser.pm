## @file
# This file contains the WebUI-specific user handling.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
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
package WebUI::AppUser;

use strict;
use base qw(Webperl::AppUser);
use Digest::MD5 qw(md5_hex);
use Webperl::Utils qw(trimspace);


## @method $ get_user($username, $onlyreal)
# Obtain the user record for the specified user, if they exist. This returns a
# reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users are not be returned.
#
# @param username The username of the user to obtain the data for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user {
    my $self     = shift;
    my $username = shift;
    my $onlyreal = shift;

    my $user = $self -> _get_user("username", $username, $onlyreal, 1)
        or return undef;

    return $self -> _make_user_extradata($user);
}


## @method $ get_user_byid($userid, $onlyreal)
# Obtain the user record for the specified user, if they exist. This returns a
# reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users are not be returned.
#
# @param userid   The id of the user to obtain the data for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user_byid {
    my $self     = shift;
    my $userid   = shift;
    my $onlyreal = shift;

    # obtain the user record
    my $user = $self -> _get_user("user_id", $userid, $onlyreal)
        or return undef;

    return $self -> _make_user_extradata($user);
}


## @method $ get_user_byemail($email, $onlyreal)
# Obtain the user record for the user with the specified email, if available.
# This returns a reference to a hash containing the user data corresponding
# to the user with the specified email, or undef if no users have the email
# specified.  If the onlyreal argument is set, the userid must correspond to
# 'real' user - bots or inactive users should not be returned.
#
# @param email    The email address to find an owner for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the email
#         address can not be located (or is not real)
sub get_user_byemail {
    my $self     = shift;
    my $email    = shift;
    my $onlyreal = shift;

    my $user = $self -> _get_user("email", $email, $onlyreal, 1)
        or return undef;

    return $self -> _make_user_extradata($user);
}


## @method $ set_user_setting($uid, $name, $value)
# Set the specified configuration setting for the user to the provided value.
# If value is undef, the setting is removed for this user.
#
# @param uid   The ID of the user to set the setting for.
# @param name  The name of the setting to set for the user.
# @param value The value to set for the setting. If this is undef, the
#              setting for the user is removed.
# @return true on success, undef on error.
sub set_user_setting {
    my $self  = shift;
    my $uid   = shift;
    my $name  = shift;
    my $value = shift;

    $self -> clear_error();

    # If no value has been specified, just go ahead and delete the setting
    return $self -> _delete_user_setting($uid, $name)
        if(!defined($value));

    # Otherwise, determine whether a setting is already present
    my $current = $self -> get_user_setting($uid, $name)
        or return undef;

    # Setting is present, update the old value
    if($current -> {"id"}) {
        return $self -> _update_user_setting($current -> {"id"}, $value);

    # Otherwise insert a new row
    } else {
        return $self -> _add_user_setting($uid, $name, $value);
    }
}


## @method $ get_user_setting($uid, $name)
# Obtain the setting information for the specified user.
#
# @param uid  The ID of the user to fetch the configuation setting for.
# @param name The name of the setting to fetch.
# @return A reference to a hash containing the setting information if it is
#         set for the user, a reference to an empty hash if it is not, or
#         undef on error.
sub get_user_setting {
    my $self = shift;
    my $uid  = shift;
    my $name = shift;

    $self -> clear_error();

    my $geth = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"user_settings"}."`
                                            WHERE `user_id` = ?
                                            AND `name` LIKE ?");
    $geth -> execute($uid, $name)
        or return $self -> self_error("Unable to fetch user setting: ".$self -> {"dbh"} -> errstr);

    return ($geth -> fetchrow_hashref() || {});
}


# @method $ post_authenticate($username, $password, $auth, $authmethod, $extradata)
# Perform any system-specific post-authentication tasks on the specified
# user's data. This function allows each system to tailor post-auth tasks
# to the requirements of the system. This function is only called if
# authentication has been successful (one of the AuthMethods has indicated
# that the user's credentials are valid), and if it returns undef the
# authentication is treated as having failed even if the user's credentials
# are valid.
#
# @note The implementation provided here will create an empty user record
#       if one with the specified username does not already exist. The
#       user is initialised as a type 0 ('normal') user, with default
#       values for all the fields. If this behaviour is not required or
#       desirable, subclasses may wish to override this function completely.
#
# @param username   The username of the user to perform post-auth tasks on.
# @param password   The password the user authenticated with.
# @param auth       A reference to the auth object calling this.
# @param authmethod The id of the authmethod to set for the user.
# @param extradata  An optional reference to a hash containin extra data to set.
# @return A reference to a hash containing the user's data on success,
#         undef otherwise. If this returns undef, an error message will be
#         set in the specified auth's errstr field.
sub post_authenticate {
    my $self       = shift;
    my $username   = shift;
    my $password   = shift;
    my $auth       = shift;
    my $authmethod = shift;
    my $extradata  = shift;

    # Let the superclass handle user creation
    my $user = $self -> SUPER::post_authenticate($username, $password, $auth, $authmethod, $extradata);
    return undef unless($user);

    $user = $self -> _set_user_extradata($user, $extradata) or return undef
        if($extradata);

    # User now exists, determine whether the user is active
    return $self -> post_login_checks($user, $auth)
        if($user -> {"activated"});

    # User is inactive, does the account need activating?
    if(!$user -> {"act_code"}) {
        # No code provided, so just activate the account
        if($self -> activate_user_byid($user -> {"user_id"})) {
            return $user; #$self -> post_login_checks($user, $auth)
        } else {
            return $auth -> self_error($self -> {"errstr"});
        }
    } else {
        return $auth -> self_error("User account is not active.");
    }
}


## @method $ post_login_checks($user, $auth)
# Perform checks on the specified user after they have logged in (post_authenticate is
# going to return the user record). This ensures that the user has the appropriate
# roles and settings.
#
# @todo This needs to invoke the enrolment engine to make sure the user has the
#       appropriate per-course roles assigned.
#
# @param user A reference to a hash containing the user's data.
# @param auth A reference to the auth object calling this.
# @return A reference to a hash containing the user's data on success,
#         undef otherwise. If this returns undef, an error message will be
#         set in to the specified auth's errstr field.
sub post_login_checks {
    my $self = shift;
    my $user = shift;
    my $auth = shift;

    # All users must have the user role in the metadata root
    my $roleid  = $self -> {"system"} -> {"roles"} -> role_get_roleid("user");
    my $root    = $self -> {"system"} -> {"roles"} -> {"root_context"};
    my $hasrole = $self -> {"system"} -> {"roles"} -> user_has_role($root, $user -> {"user_id"}, $roleid);

    # Give up if the role check failed.
    return $auth -> self_error($self -> {"system"} -> {"roles"} -> {"errstr"})
        if(!defined($hasrole));

    # Try to assign the role if the user does not have it.
    $self -> {"system"} -> {"roles"} -> user_assign_role($root, $user -> {"user_id"}, $roleid)
        or return $auth -> self_error($self -> {"system"} -> {"roles"} -> {"errstr"})
        if(!$hasrole);

    # TODO: Assign other roles as needed.

    return $user;
}


# ============================================================================
#  Internal functions

## @method private $ _make_user_extradata($user)
# Generate the 'calculated' user fields - full name, gravatar hash, etc.
#
# @param user A reference to the user hash to work on.
# @return The user hash reference.
sub _make_user_extradata {
    my $self = shift;
    my $user = shift;

    # Generate the user's full name
    $user -> {"fullname"} = $user -> {"realname"} || $user -> {"username"};

    # Make the user gravatar hash
    $user -> {"gravatar_hash"} = md5_hex(lc(trimspace($user -> {"email"} || "")));

    return $user;
}


## @method private $ _add_user_setting($uid, $name, $value)
# Add a setting for the specified user to the database. This will add a new
# setting for the user, it does not check if the setting is already present.
#
# @param uid   The ID of the user to set the setting for.
# @param name  The name of the setting to set for the user.
# @param value The value to set for the setting. If this is undef, the
#              setting for the user is removed.
# @return true on success, undef on error.
sub _add_user_setting {
    my $self  = shift;
    my $uid   = shift;
    my $name  = shift;
    my $value = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"user_settings"}."`
                                            (`user_id`, `name`, `value`)
                                            VALUES(?, ?, ?)");
    my $rows = $newh -> execute($uid, $name, $value);
    return $self -> self_error("Unable to perform user setting insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("User setting insert failed, no rows inserted") if($rows eq "0E0");

    return 1;
}


## @method private $ _update_user_setting($id, $value)
# Update a setting for a user. This updates the value associated with the
# specified user setting
#
# @param id    The ID of the user setting row to update the value in
# @param value The value to set in the setting row.
# @return true on success, undef on error
sub _update_user_setting {
    my $self  = shift;
    my $id    = shift;
    my $value = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"user_settings"}."`
                                            SET `value` = ?
                                            WHERE `id` = ?");
    my $rows = $seth -> execute($value, $id);
    return $self -> self_error("Unable to perform user setting update: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("User setting update failed, no rows inserted") if($rows eq "0E0");

    return 1;
}


## @method private $ _delete_user_setting($uid, $name)
# Remove a setting for the specified user from the database. This will remove
# the setting if it exists; non-existence is not considered an error.
#
# @param uid  The ID of the user to delete the setting for.
# @param name The name of the setting to delete.
# @return true on success, undef on error.
sub _delete_user_setting {
    my $self = shift;
    my $uid  = shift;
    my $name = shift;

    $self -> clear_error();

    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM `".$self -> {"settings"} -> {"database"} -> {"user_settings"}."`
                                             WHERE `user_id` = ?
                                             AND `name` LIKE ?");
    $nukeh -> execute($uid, $name)
        or return $self -> self_error("Unable to delete user setting: ".$self -> {"dbh"} -> errstr);

    return 1;
}


## @method private $ _set_user_extradata($user, $extradata)
# Update the name and email fields for the user to the values given in
# the specified extradata, if they are not already set.
#
# @param user      A reference to a hash containing the user's data.
# @param extradata A reference to a hash containing the name and email to set.

sub _set_user_extradata {
    my $self      = shift;
    my $user      = shift;
    my $extradata = shift;

    # do nothing if there's no extradata at all
    return $user unless($extradata);

    if($extradata -> {"fullname"}) {
        my $set = $self -> _set_user_field($user -> {"user_id"}, 'realname', $extradata -> {"fullname"});
        return undef if(!defined($set));

        $user -> {"realname"} = $extradata -> {"fullname"} if($set);
    }

    if($extradata -> {"email"}) {
        my $set = $self -> _set_user_field($user -> {"user_id"}, 'email', $extradata -> {"email"});
        return undef if(!defined($set));

        $user -> {"email"} = $extradata -> {"email"} if($set);
    }

    return $user;
}


## @method private $ _set_user_field($userid, $field, $value)
# Set the vlaue of the specified field for the indicated user if it has not already been set.
#
# @param userid The ID of the user to set the field for.
# @param field  The name of the field to set.
# @param value  The value to set for the field.
# @return true if the value was updated, false if not, undef on error.
sub _set_user_field {
    my $self   = shift;
    my $userid = shift;
    my $field  = shift;
    my $value  = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"users"}."`
                                            SET `$field` = ?
                                            WHERE `user_id` = ?
                                            ANd `$field` IS NULL");
    my $rows = $seth -> execute($value, $userid);
    return $self -> self_error("Unable to perform user update: ". $self -> {"dbh"} -> errstr) if(!$rows);

    return($rows > 0 ? 1 : 0);
}

1;
