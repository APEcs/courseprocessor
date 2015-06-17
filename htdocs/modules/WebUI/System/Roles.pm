## @file
# This file contains the implementation of the Role handling engine.
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
# This class encapsulates operations involving roles in the system. The methods
# in this class provide the rest of the system with the ability to query user's
# roles and capabilities, as well as assign roles to users, remove those assignments,
# and define the capabilities of roles.
#
package WebUI::System::Roles;

use strict;
use base qw(Webperl::SystemModule);

# ==============================================================================
# Creation

## @cmethod $ new(%args)
# Create a new Roles object to manage user role allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Roles object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(root_context => 1,
                                        @_)
        or return undef;

    # Check that the required objects are present
    return Webperl::SystemModule::set_error("No metadata object available.") if(!$self -> {"metadata"});

    return $self;
}


# ==============================================================================
# Public interface - user-centric role functions.

## @method $ user_capabilities($metadataid, $userid, $rolelimit)
# Obtain a hash of user capabilities for the specified metadata context. This will
# check the specified metadata context and all its parents to create a full
# set of capabilities the user has in the context.Normal role combination rules apply
# (higher priority roles will take precedent over lower priority roles), except
# that all metadata levels from the specified level to the root are considered.
# If `rolelimit` is specified, only roleids present in the hash will be included
# when determining whether the user has the requested capability.
#
# @param metadataid The ID of the metadata context to start searching from. This
#                   will generally be the context associated with the resource
#                   checking the user's capabilities.
# @param userid     The ID of the user to establish the capabilities of.
# @param rolelimit  An optional hash containing role ids as keys, and true or
#                   false as values. If a role id's value is true, the role
#                   will be allowed through to capability testing, otherwise
#                   the role is excluded from capability testing. IMPORTANT:
#                   specifying this hash *does not* grant the user any roles they
#                   do not already have - this is used to conditionally exclude
#                   roles the user *does* have from capability testing, not grant
#                   roles!
# @return A reference to a capability hash on success, undef on error.
sub user_capabilities {
    my $self       = shift;
    my $metadataid = shift;
    my $userid     = shift;
    my $rolelimit  = shift;

    $self -> clear_error();

    # User roles will accumulate in here...
    my $user_roles = {};

    # Now get all the roles the user has from this metadata context to the root
    while($metadataid) {
        # Fetch the roles for the user set at this metadata level, give up if there was
        # an error doing it.
        my $roles = $self -> metadata_assigned_roles($metadataid, $userid);
        return undef if(!defined($roles));

        # copy over any roles set...
        foreach my $role (keys(%{$roles})) {
            # skip any roles not present in $rolelimit, if needed
            next if($rolelimit && !$rolelimit -> {$role});

            $user_roles -> {$role} = $roles -> {$role};
        }

        # go up a level if possible
        $metadataid = $self -> {"metadata"} -> parentid($metadataid);
    }

    # $user_roles now contains an unsorted hash of roleids and priorities,
    # we need a sorted list of roleids, highest priority last so that higher
    # priorities overwrite lower
    my @roleids = sort { $user_roles -> {$a} <=> $user_roles -> {$b} } keys(%{$user_roles});

    my $capabilities = {};
    # Now fo through each role, merging the role capabilities into the
    # capabilities hash
    foreach my $roleid (@roleids) {
        my $rolecaps = $self -> role_get_capabilities($roleid);

        # Merge the new capabilities into the ones collected so far, this will
        # overwrite any capabilities already defined - hence the need to sort above!
        @{$capabilities}{keys %{$rolecaps}} = values %{$rolecaps};
    }

    return $capabilities;
}


## @method $ user_has_capability($metadataid, $userid, $capability, $rolelimit)
# Determine whether the user has the specified capability within the metadata
# context. This will search the current metadata context, and its parents, to
# determine whether the user has the capability requested, and if so whether
# that capability is enabled or disabled. Normal role combination rules apply
# (higher priority roles will take precedent over lower priority roles), except
# that all metadata levels from the specified level to the root are considered.
# If `rolelimit` is specified, only roleids present in the hash will be included
# when determining whether the user has the requested capability.
#
# @param metadataid The ID of the metadata context to start searching from. This
#                   will generally be the context associated with the resource
#                   checking the user's capabilities.
# @param userid     The ID of the user to establish the capabilities of.
# @param capability The name of the capability the user needs.
# @param rolelimit  An optional hash containing role ids as keys, and true or
#                   false as values. If a role id's value is true, the role
#                   will be allowed through to capability testing, otherwise
#                   the role is excluded from capability testing. IMPORTANT:
#                   specifying this hash *does not* grant the user any roles they
#                   do not already have - this is used to conditionally exclude
#                   roles the user *does* have from capability testing, not grant
#                   roles!
# @return true if the user has the requested capability, false if they do not, undef
#         if an error was encountered.
sub user_has_capability {
    my $self       = shift;
    my $metadataid = shift;
    my $userid     = shift;
    my $capability = shift;
    my $rolelimit  = shift;

    $self -> clear_error();

    # Has the user's capability at this metadata level been queried before? If so, use the cached value.
    # In most cases this will probably miss, but it's not like it is a big overhead.
    return $self -> {"cache"} -> {"user"} -> {$userid} -> {"capabilities"} -> {$metadataid} -> {$capability}
        if(defined($self -> {"cache"} -> {"user"} -> {$userid} -> {"capabilities"} -> {$metadataid} -> {$capability}));

    # User roles will accumulate in here...
    my $user_roles = {};

    # Need to preserve the original ID for caching, so copy it...
    my $currentmdid = $metadataid;

    # Now get all the roles the user has from this metadata context to the root
    while($currentmdid) {
        # Fetch the roles for the user set at this metadata level, give up if there was
        # an error doing it.
        my $roles = $self -> metadata_assigned_roles($currentmdid, $userid);
        return undef if(!defined($roles));

        # copy over any roles set...
        foreach my $role (keys(%{$roles})) {
            # skip any roles not present in $rolelimit, if needed
            next if($rolelimit && !$rolelimit -> {$role});

            $user_roles -> {$role} = $roles -> {$role};
        }

        # FUTURE: At this point, discontinuities could be introduced into the role
        # inheritance hierarchy by halting tree climbing if the metadata indicates
        # inheritance should break here. However, doing so would probably need special
        # edge-cases for admin users.

        # go up a level if possible
        $currentmdid = $self -> {"metadata"} -> parentid($currentmdid);
    }

    # $user_roles now contains an unsorted hash of roleids and priorities,
    # we need a sorted list of roleids, highest priority first, to check for
    # the capability.
    my @roleids = sort { $user_roles -> {$b} <=> $user_roles -> {$a} } keys(%{$user_roles});

    # Go through the list of roles, determining whether the role sets the
    # capability in some fasion
    my $set_capability;
    foreach my $role (@roleids) {
        $set_capability = $self -> role_has_capability($role, $capability);
        return undef if(defined($set_capability) && $set_capability eq "error");

        # stop if a setting for the capability has been located
        last if($set_capability);
    }

    # If set_capability is still undefined, none of the roles defined the capability,
    # so set it to the default 'deny'
    $set_capability = "deny" unless(defined($set_capability));

    # store the result in the cache
    $self -> {"cache"} -> {"user"} -> {$userid} -> {"capabilities"} -> {$metadataid} -> {$capability} = ($set_capability eq "allow");

    # And done
    return $self -> {"cache"} -> {"user"} -> {$userid} -> {"capabilities"} -> {$metadataid} -> {$capability};
}


## @method $ user_has_role($metadataid, $userid, $roleid, $sourceid, $check_tree)
# Determine whether the user has the specified role in the current metadata context.
# If sourceid is specified, only roles granted by the corresponding enrolment source
# will be considered when checking for the role. If $check_tree is set, this will
# not only check the specified metadata context for the role, but any parent context,
# until either the role is found or the search fails at the root. Byt default, only
# the specified metadata context is checked.
#
# @param metadataid The ID of the metadata context to check.
# @param userid     The ID of the user to check the role for.
# @param roleid     The ID of the role to look for.
# @param sourceid   If specified, only roles granted by this enrolment source are considered.
# @param check_tree If true, this function will walk back up the tree trying to locate
#                   any assignment of the role. Otherwise, only the specified context is
#                   checked.
# @return true if the user has the role, false if the user does not, and undef on error.
sub user_has_role {
    my $self = shift;
    my ($metadataid, $userid, $roleid, $sourceid, $check_tree) = @_;

    $self -> clear_error();

    # Note lack of caching - while it would be possible to cache the result of this, doing
    # so is likely to introduce subtle bugs. Caching can be added in future if needed.
    my $has_role;
    do {
        $has_role = $self -> _fetch_user_role($metadataid, $userid, $roleid, $sourceid);
        # _fetch_user_role returns undef when the role hasn't been granted, or error. Check errors...
        return undef if($self -> {"errstr"});

        # Otherwise, try going up to the parent
        $metadataid = $self -> {"metadata"} -> parentid($metadataid);
    } while(!$has_role && $check_tree && $metadataid);

    return defined($has_role);
}


## @method $ user_assign_role($metadataid, $userid, $roleid, $sourceid, $groupid)
# Assign the user a role in the specified metadata context. This will give the user
# the role, if the user does not already have it. If the user has the role, this
# will update the persist flag if it differs.
#
# @note Users may be given the same role by different enrolment sources, and the
#       persist flag may be different for each source. This means that the user
#       may have Role A set by Source A, and Role A set by Source B. In practice
#       this feature is unlikely to be needed or used, but is provided Just In Case.
#
# @param metadataid The ID of the metadata context to grant the role in.
# @param userid     The ID of the user to grant the role to.
# @param roleid     The ID of the role to grant.
# @param sourceid   The ID of the enrolment source granting the role.
# @param groupid    The ID of the group this is an assignment for. If this is an
#                   individual assignment rather than a group assignment, set this
#                   to undef.
# @return true on success, false if an error occurred.
sub user_assign_role {
    my $self = shift;
    my ($metadataid, $userid, $roleid, $sourceid, $groupid) = @_;

    $self -> clear_error();

    # Try to get the role, bomb if an error occurred
    my $role = $self -> _fetch_user_role($metadataid, $userid, $roleid, $sourceid, $groupid);
    return undef if(!$role && $self -> {"errstr"});

    my $rows;
    # no role found? Try to assign it.
    if(!$role) {
        my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."
                                                (metadata_id, role_id, user_id, source_id, group_id, attached, touched)
                                                VALUES(?, ?, ?, ?, ?, UNIX_TIMESTAMP(), UNIX_TIMESTAMP())");
        $rows = $newh -> execute($metadataid, $roleid, $userid, $sourceid, $groupid);
        return $self -> self_error("Unable to perform metadata role insert: ". $self -> {"dbh"} -> errstr) if(!$rows);

        # If a row has been added, increment the metadata's refcount
        $rows = $self -> {"metadata"} -> attach($metadataid)
            if($rows ne "0E0");

    # A role has been located in this context that matches the user and source,
    # update its touched timestamp
    } else {
        my $oldh = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."
                                                SET touched = UNIX_TIMESTAMP(),
                                                WHERE id = ?");
        $rows = $oldh -> execute($role -> {"id"});
        return $self -> self_error("Unable to perform metadata role update: ". $self -> {"dbh"} -> errstr) if(!$rows);
    }

    # Check that a row has been modified before finishing.
    return $self -> self_error("Role assignment failed: no rows modified") if($rows eq "0E0");

    return 1;
}


## @method $ user_remove_role($metadataid, $userid, $roleid, $sourceid, $groupid)
# Remove a role from a user in the specified metadata context. If the user does
# not have the role in the context, this does nothing, and this function *will not*
# traverse the tree looking for any assignment of the role to the user: it will
# inspect the specified metadata context only. If sourceid is not specified, the
# role is guaranteed to be entirely removed from the user in the context if it was
# set there. If sourceid is provided, only the role allocation previously made by
# the specified source will be removed, and any other copies of the role allocation
# made by other sources will remain in effect.
#
# @param metadataid The ID of the metadata context to remove the role in.
# @param userid     The ID of the user to remove the role from.
# @param roleid     The ID of the role to remove.
# @param sourceid   The ID of the enrolment source removing the role, or undef if
#                   copies of the role applied by all sources should be removed.
# @param groupid    The ID of the group this is a removal for.
# @return true on success, false if an error occurred.
sub user_remove_role {
    my $self = shift;
    my ($metadataid, $userid, $roleid, $sourceid, $groupid) = @_;

    $self -> clear_error();

    my @args  = ($metadataid, $roleid, $userid, $groupid);
    my $query = "DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."
                 WHERE metadata_id = ?
                 AND role_id = ?
                 AND user_id = ?
                 AND group_id = ?";

    if($sourceid) {
        $query .= " AND source_id = ?";
        push(@args, $sourceid);
    }

    my $nukeh = $self -> {"dbh"} -> prepare($query);
    my $rows = $nukeh -> execute(@args);

    return $self -> self_error("Unable to perform metadata role delete: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Metadata context delete failed: no rows removed") if($rows eq "0E0");

    # Removal worked, so decrement the refcount
    my $refcount = $self -> {"metadata"} -> detach($metadataid);
    return defined($refcount);
}


## @method $ get_role_users($metadataid, $roleids, $sourceid)
# Obtain a list of users who have the specified role at this metadata level. If
# the sourceid is specified, only roles allocated by the specified source are
# considered when constructing the list.
#
# @param metadataid The ID of the metadata context to list users from.
# @param roles      The name or ID of the role that has been assigned to users, or a
#                   reference to an array of names or IDs. If not set, any roles
#                   allocated to users at this level are returned.
# @param inherited  If true, include roles the user has inherited at the
#                   specified metadata context. If false (the default), only
#                   roles allocated at the specified metadata context are listed.
# @param sourceid   The ID of the enrolment source that allocated the role, or
#                   undef if any source is acceptable
# @return A reference to a hash of hashrefs, each key in the outer hash is a userid
#         while the subhashes contain role names and IDs:
#         { "user_id" => { "rolename" => id, "rolename" => id } }
sub get_role_users {
    my $self       = shift;
    my $metadataid = shift;
    my $roles      = shift;
    my $inherited  = shift;
    my $sourceid   = shift;

    $self -> clear_error();

    my $filters = "";
    my @params  = ($metadataid);

    if($roles) {
        # Force an array of role IDs, even for a single ID.
        $roles = [ $roles ] unless(ref($roles) eq "ARRAY");

        # convert names to IDs if needed
        foreach my $role (@{$roles}) {
            next if($role =~ /^\d+$/); # skip numeric roles (assume it's an ID)

            # Attempt the lookup.
            my $roleid = role_get_roleid($self, $role)
                or return $self -> self_error("Unable to map role name '$role' to an ID. Role does not exist?");

            $role = $roleid;
        }

        # The filter string needs to use IN, with enough placeholders for each ID specified.
        $filters = " AND `mr`.`role_id` IN (?".(",?" x (scalar(@{$roles}) - 1)).")";
        push(@params, @{$roles});
    }

    if($sourceid) {
        $filters .= " AND `mr`.`source_id` = ? ";
        push(@params, $sourceid);
    }

    # Fetch the role allocations at this level
    my $rolesh = $self -> {"dbh"} -> prepare("SELECT `u`.`user_id`,`r`.`id`,`r`.`role_name`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."` AS `mr`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"roles"}."` AS `r`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"users"}."` As `u`
                                              WHERE `r`.`id` = `mr`.`role_id`
                                              AND `u`.`user_id` = `mr`.`user_id`
                                              AND `mr`.`metadata_id` = ?
                                              $filters
                                              ORDER BY `r`.`role_name`, `u`.`username`");

    # And a query to allow tree walking
    my $metah = $self -> {"dbh"} -> prepare("SELECT `parent_id`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"metadata"}."`
                                             WHERE `id` = ?");
    my $user_roles = {};
    do {
        # Fetch the list of role allocations at the current metadata level
        $rolesh -> execute(@params)
            or return $self -> self_error("Role allocation lookup failed: ".$self -> {"dbh"} -> errstr);

        # And store them in a way that ORs them together
        # FIXME: This does not take tree discontinuities/default roles into account.
        while(my $role = $rolesh -> fetchrow_hashref()) {
            $user_roles -> {$role -> {"user_id"}} -> {$role -> {"role_name"}} -> {"id"} = $role -> {"id"};
            push(@{$user_roles -> {$role -> {"user_id"}} -> {$role -> {"role_name"}} -> {"contexts"}}, $params[0]);
        }

        # Try to get the parent metadata context for this one
        $metah -> execute($params[0])
            or return $self -> self_error("Metadata parent lookup failed: ".$self -> {"dbh"} -> errstr);

        my $meta = $metah -> fetchrow_arrayref();
        $params[0] = $meta ? $meta -> [0] : undef;

    # keep working unless inherited roles are not needed, or the context has no parent.
    } while($inherited && $params[0]);

    return $user_roles;
}


## @method $ get_capability_users($metadataid, $capability, $inherited, $sourceid)
# Obtain a list of users with the specified capability at the provided metadata
# context. If the sourceid is specified, only roles allocated by the specified
# source are considered when constructing the list.
#
# @param metadataid The ID of the metadata context to list users from.
# @param capability The name of the capability to search for.
# @param inherited  If true, include roles the user has inherited at the
#                   specified metadata context. If false (the default), only
#                   roles allocated at the specified metadata context are listed.
# @param sourceid   The ID of the enrolment source that allocated the role, or
#                   undef if any source is acceptable
# @return A reference to a hash of hashrefs, each key in the outer hash is a userid
#         while the subhashes contain the role names and IDs that gave the user the
#         capability@ { "user_id" => { "rolename" => id, "rolename" => id } }
sub get_capability_users {
    my $self       = shift;
    my $metadataid = shift;
    my $capability = shift;
    my $inherited  = shift;
    my $sourceid   = shift;

    $self -> clear_error();

    my $rolesh = $self -> {"dbh"} -> prepare("SELECT `role_id`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."`
                                              WHERE `capability` LIKE ?");
    $rolesh -> execute($capability)
        or return $self -> self_error("Capability lookup failed: ".$self -> {"dbh"} -> errstr);

    # build the list of roles that provide this capability
    my @roles = ();
    while(my $role = $rolesh -> fetchrow_arrayref()) {
        push(@roles, $role -> [0]);
    }

    # No roles have this capability? Give up
    return $self -> self_error("No roles grant the requested '$capability' capability") if(!scalar(@roles));

    # Now look up who has the roles
    return $self -> get_role_users($metadataid, \@roles, $inherited, $sourceid);
}


# ==============================================================================
# Public interface - role-centric role functions.

## @method $ create($name, $priority, $capabilities)
# Create a new role, initialising it with the specified priority and capabilities.
#
# @param name         The name of the role. If a role already exists with this name,
#                     the function will abort.
# @param priority     The role priority, in the range 0 (lowest) to 255 (highest).
# @param capabilities A reference to a hash containing the capabilities to set for
#                     the role. Keys should be capability names, and the values should
#                     be true for 'allow' and false for 'deny'. Set this to undef to
#                     skip capability settings.
# @return The new role ID on success, undef on error.
sub create {
    my $self         = shift;
    my $name         = shift;
    my $priority     = shift;
    my $capabilities = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"roles"}."
                                            (name, priority)
                                            VALUES(?, ?)");
    my $rows = $newh -> execute($name, $priority);
    return $self -> self_error("Unable to perform role insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Role insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $roleid = $self -> {"dbh"} -> {"mysql_insertid"};
    return $self -> self_error("Unable to obtain roleid for role '$name'") if(!$roleid);

    # Skip capability setting if there are no capabilities to set.
    return $roleid if(!$capabilities);

    # Set up the capabilities
    return $self -> role_set_capabilities($roleid, $capabilities) ? $roleid : undef;
}


## @method $ destroy($roleid)
# Attempt to remove the specified role, and any capabilities associated with it, from
# the system.
#
# @warning This will remove the role, the capabilities set for the role, and any
#          role assignments. It will work even if there are users currently allocated
#          this role. Use with extreme caution!
#
# @param roleid The ID of the role to remove from the system
# @return true on success, undef on error
sub destroy {
    my $self   = shift;
    my $roleid = shift;

    $self -> clear_error();

    # Delete any role assignments first. This is utterly indiscriminate, if this breaks
    # something important, don't say I didn't warn you.
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."
                                             WHERE role_id = ?");
    $nukeh -> execute($roleid)
        or return $self -> self_error("Unable to perform role allocation removal: ". $self -> {"dbh"} -> errstr);

    # Now delete the capabilities
    $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."
                                          WHERE role_id = ?");
    $nukeh -> execute($roleid)
        or return $self -> self_error("Unable to perform role capability removal: ". $self -> {"dbh"} -> errstr);

    # And now the role itself
    $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"roles"}."
                                          WHERE id = ?");
    $nukeh -> execute($roleid)
        or return $self -> self_error("Unable to perform role removal: ". $self -> {"dbh"} -> errstr);

    # Trash the cache, too, just in case
    $self -> {"cache"} = {};

    return 1;
}


## @method $ set_priority($roleid, $priority)
# Update the priority for the specified role.
#
# @param roleid   The role to update the priority for.
# @param priority The new priority for the role.
# @return true on success, undef on error.
sub set_priority {
    my $self     = shift;
    my $roleid   = shift;
    my $priority = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"roles"}."
                                            SET priority = ?
                                            WHERE id = ?");
    my $rows = $seth -> execute($priority, $roleid);
    return $self -> self_error("Unable to perform role priority update: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Role priority update failed: no rows updated (possibly bad role id $roleid)") if($rows eq "0E0");

    # This could invalidate the cache, so clear it
    $self -> {"cache"} = {};

    return 1;
}


## @method $ get_priority($roleid)
# Obtain the priority of the specified role.
#
# @param roleid The role to obtain the priority for.
# @return The priority of the role on success (note this may be zero!), undef on error.
sub get_priority {
    my $self     = shift;
    my $roleid   = shift;

    $self -> clear_error();

    my $geth = $self -> {"dbh"} -> prepare("SELECT priority FROM ".$self -> {"settings"} -> {"database"} -> {"roles"}."
                                            WHERE id = ?");
    $geth -> execute($roleid)
        or return $self -> self_error("Unable to perform role priority lookup: ". $self -> {"dbh"} -> errstr);

    my $role = $geth -> fetchrow_arrayref();

    return $role ? $role -> [0] : $self -> self_error("Role priority lookup failed: bad role id $roleid");
}


## @method $ role_get_roleid($name)
# Given a role name, obtain the id of the role.
#
# @param name The name of the role to look up.
# @return The id of the role, or undef if the role name is not valid or an error
#         occurred.
sub role_get_roleid {
    my $self = shift;
    my $name = shift;

    $self -> clear_error();

    my $roleh = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"roles"}."
                                             WHERE role_name LIKE ?");
    $roleh -> execute($name)
        or return $self -> self_error("Unable to perform role lookup: ". $self -> {"dbh"} -> errstr);

    # Return the role id if it is found, otherwise undef.
    my $role = $roleh -> fetchrow_arrayref();
    return $role ? $role -> [0] : undef;
}


## @method $ role_has_capability($roleid, $capability)
# Determine whether the specified role defines the requested capability. This will
# check whether the capability is defined for the role, and if it is return the
# value that is set for its mode. If the capability is not set for the role,
# this returns undef.
#
# @param roleid     The ID of the role to check.
# @param capability The name of the capability to look for in the role.
# @return 'allow' or 'deny' if the role sets the capability, undef otherwise.
#         This will return 'error' if an error was encountered.
sub role_has_capability {
    my $self       = shift;
    my $roleid     = shift;
    my $capability = shift;

    # Is the value cached?
    if($self -> {"cache"} -> {"role"} -> {$roleid} -> {$capability}) {
        # If the cache indicates the value is undefined for this role, return undef, otherwise return
        # the cached value.
        return undef if($self -> {"cache"} -> {"role"} -> {$roleid} -> {$capability} eq "undef");
        return $self -> {"cache"} -> {"role"} -> {$roleid} -> {$capability};
    }

    # Ask the database for the capability definition, if provided
    my $set_capability = $self -> _fetch_role_capability($roleid, $capability);
    return "error" if(defined($set_capability) && $set_capability eq "error");

    # Cache the result
    $self -> {"cache"} -> {"role"} -> {$roleid} -> {$capability} = defined($set_capability) ? $set_capability : "undef";

    return $set_capability;
}


## @method $ role_get_capabilities($roleid)
# Obtain a hash containing the capabilities defined for the specified role. This
# will pull the role capability settings out of the database and return a hash
# containing the capability names as keys and their mode as the value. The value
# is true if the mode is 'allow', and false if it is 'deny'.
#
# @param roleid The ID of the role to obtain capability data for.
# @return A reference to a hash containing role capabilities on success, undef
#         on error.
sub role_get_capabilities {
    my $self   = shift;
    my $roleid = shift;

    $self -> clear_error();

    # There's no need to order the results of this, as it's going into a hash anyway
    my $caph = $self -> {"dbh"} -> prepare("SELECT capability, mode
                                            FROM ".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."
                                            WHERE role_id = ?");
    $caph -> execute($roleid)
        or return $self -> self_error("Unable to fetch role capability list: ".$self -> {"dbh"} -> errstr);

    # Bung the results in a hash. Would be nice to use fetchall here, but for the mode translate
    my $caphash = {};
    while(my $capability = $caph -> fetchrow_hashref()) {
        $caphash -> {$capability -> {"capability"}} = ($capability -> {"mode"} eq "allow");
    }

    return $caphash;
}


## @method $ role_set_capabilities($roleid, $capabilities)
# Update the capabilities for the specified role. This takes a hash of capabilities,
# capability names as keys and mode as value (true is 'allow', false is 'deny') and
# sets the capabilities for the role to the settings in the hash. Note that any
# capabilities not in the hash, but previously assigned to the role *will be removed*.
#
# @param roleid       The ID of the role to update.
# @param capabilities A reference to a hash containing the capabilities to set for
#                     the role. Keys should be capability names, and the values should
#                     be true for 'allow' and false for 'deny'.
# @return true on success, undef on error. Note that if an error occurs, it is possible
#         that the capability list may no longer reflect the old list, or the full
#         list specified in the capabilities hash.
sub role_set_capabilities {
    my $self         = shift;
    my $roleid       = shift;
    my $capabilities = shift;

    $self -> clear_error();

    # Nuke any existing capabilities for this role
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."
                                             WHERE role_id = ?");
    $nukeh -> execute($roleid)
        or return $self -> self_error("Unable to delete capabilities for role $roleid: ".$self -> {"dbh"} -> errstr);

    # Now insert new capabilities
    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."
                                            (role_id, capability, mode)
                                            VALUES(?, ?, ?)");
    foreach my $capability (keys(%{$capabilities})) {
        my $inserted = $newh -> execute($roleid, $capability, $capabilities -> {$capability} ? "allow" : "deny");

        return $self -> self_error("Unable to give capability $capability to role $roleid: ".$self -> {"dbh"} -> errstr)
            if(!$inserted);

        return $self -> self_error("Unable to give capability $capability to role $roleid: row insertion failed")
            if($inserted eq "0E0");
    }

    # Reset the cache, to prevent stale values causing problems
    $self -> {"cache"} = {};

    return 1;
}


# ==============================================================================
# Public-ish, mostly internal metadata bridge

## @method $ metadata_assigned_roles($metadataid, $userid)
# Obtain a hash of roles defined for the user in the specified metadata context. This
# returns only the roles defined *in the specified metadata*, it does not include any
# roles defined in any parents. If no roles are defined at this level, an empty hash
# is returned, otherwise the returned hash contains the roleids as keys and their
# priorities as values.
#
# @param metadataid The ID of the metadata context to fetch user roles for.
# @param userid     The ID of the user to fetch roles for.
# @return A hash containing the roles set at this level, role ids as keys and
#         role priorities as values. If any errors are encountered, this returns
#         undef and the error message is stored in $self -> {"errstr"}
sub metadata_assigned_roles {
    my $self       = shift;
    my $metadataid = shift;
    my $userid     = shift;

    # Are the user's roles at this level cached?
    return $self -> {"cache"} -> {"user"} -> {$userid} -> {"roles"} -> {$metadataid}
        if(defined($self -> {"cache"} -> {"user"} -> {$userid} -> {"roles"} -> {$metadataid}));

    # Not cached, try to fetch them
    my $roles = $self -> _fetch_metadata_roles($metadataid, $userid);
    return undef if(!defined($roles));

    $self -> {"cache"} -> {"user"} -> {$userid} -> {$metadataid} -> {"roles"} = $roles;

    return $roles;
}


# ==============================================================================
# Private methods

## @method private $ _fetch_metadata_roles($metadataid, $userid)
# Fetch the roles set for the user at the specified metadata level. If there
# are no roles for the user attached to the specified metadata id, this returns
# an empty roles hash, otherwise it will return a hash containing the ids of
# any roles set and their priorities.
#
# @param metadataid The ID of the metadata context to fetch user roles for.
# @param userid     The ID of the user to fetch roles for.
# @return A hash containing the roles set at this level, role ids as keys and
#         role priorities as values. If any errors are encountered, this returns
#         undef and the error message is stored in $self -> {"errstr"}
sub _fetch_metadata_roles {
    my $self       = shift;
    my $metadataid = shift;
    my $userid     = shift;
    my $set_roles = {};

    $self -> clear_error();

    # Pull the list of roles, highest priority first
    my $roleh = $self -> {"dbh"} -> prepare("SELECT r.id, r.priority
                                             FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}." AS m,
                                                  ".$self -> {"settings"} -> {"database"} -> {"roles"}." AS r
                                             WHERE r.id = m.role_id
                                             AND m.metadata_id = ?
                                             AND m.user_id = ?
                                             ORDER BY r.priority DESC");
    $roleh -> execute($metadataid, $userid)
        or return $self -> self_error("Unable to perform metadata role lookup: ". $self -> {"dbh"} -> errstr);

    # Store roles set at this level, and their priorities
    while(my $role = $roleh -> fetchrow_hashref()) {
        $set_roles -> {$role -> {"id"}} = $role -> {"priority"};
    }

    # If the user has no roles in this context, and default roles have been enabled,
    # determine whether the context has a default role set.
    $set_roles = $self -> _fetch_metadata_default_role($metadataid)
        if(!scalar($set_roles) && $self -> {"settings"} -> {"database"} -> {"metadata_default_roles"});

    return $set_roles;
}


## @method private $ _fetch_metadata_default_role($metadataid)
# Obtain the default role set for the specified metadata context, and its priority, if
# the metadata context has a default role set.
#
# @param metadataid The ID of the metadata context to obtain the default role for.
# @return A reference to a hash containing the default role id and priority on
#         success, an empty hashref if no default is defined, and undef on error.
sub _fetch_metadata_default_role {
    my $self = shift;
    my $metadataid = shift;

    my $defh = $self -> {"dbh"} -> prepare("SELECT d.role_id,d.priority AS override,r.priority
                                            FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_default_roles"}." AS d,
                                                 ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}." AS r
                                            WHERE d.metadata_id = ?
                                            AND r.id = d.role_id");
    $defh -> execute($metadataid)
        or return $self -> self_error("Unable to perform metadata default role lookup: ". $self -> {"dbh"} -> errstr);

    # If a default has been specified, return a hashref with it set, otherwise just return an empty hashref.
    my $def = $defh -> fetchrow_hashref();
    return $def ? {$def -> {"role_id"} => ($def -> {"override"} || $def -> {"priority"})} : {};
}


## @method private $ _fetch_role_capability($roleid, $capability)
# Look up whether the specified role defines the requested capability, and if
# it does, return the mode defined for it.
#
# @param roleid     The ID of the role to check.
# @param capability The name of the capability to look for in the role.
# @return 'allow' or 'deny' if the role sets the capability, undef otherwise.
#         This will return 'error' if an error was encountered.
sub _fetch_role_capability {
    my $self       = shift;
    my $roleid     = shift;
    my $capability = shift;

    $self -> clear_error();

    my $roleh = $self -> {"dbh"} -> prepare("SELECT mode FROM ".$self -> {"settings"} -> {"database"} -> {"role_capabilities"}."
                                             WHERE role_id = ?
                                             AND capability LIKE ?");
    $roleh -> execute($roleid, $capability)
        or return ($self -> self_error("Unable to perform role capability lookup: ". $self -> {"dbh"} -> errstr) || "error");

    # Fetch the role's definition of the capability, and it if has one return it.
    my $role = $roleh -> fetchrow_arrayref();
    return $role ? $role -> [0] : undef;
}


## @method private $ _fetch_user_role($metadataid, $userid, $roleid, $sourceid, $groupid)
# Obtain the metadata role record for the user and role. If sourceid is specified,
# this will only return a metadata role record if it was granted by the source. If
# a group id is specified, this will only return a record if it was added as part of
# that group.
#
# @param metadataid The ID of the metadata context to look at for the role assignment.
# @param userid     The ID of the user whose role allocation should be checked.
# @param roleid     The ID of the role to look for.
# @param sourceid   Optional ID of the enrolment source that granted the role.
# @param groupid    Optional ID of a group the role assignment was made as part of.
# @return A reference to a hash containing the metadata role allocation, or undef
#         if no matching allocation was found, or an error occurred.
sub _fetch_user_role {
    my $self = shift;
    my ($metadataid, $userid, $roleid, $sourceid, $groupid) = @_;

    $self -> clear_error();

    my $query = "SELECT *
                 FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_roles"}."
                 WHERE metadata_id = ?
                 AND user_id = ?
                 AND role_id = ?";
    my @args = ($metadataid, $userid, $roleid);

    if($sourceid) {
        $query .= " AND source_id = ?";
        push(@args, $sourceid);
    }

    if($groupid) {
        $query .= " AND group_id = ?";
        push(@args, $groupid);
    }

    my $roleh = $self -> {"dbh"} -> prepare($query);
    $roleh -> execute(@args)
        or return $self -> self_error("Unable to perform metadata role lookup: ". $self -> {"dbh"} -> errstr);

    return $roleh -> fetchrow_hashref();
}

1;
