## @file
# This file contains the implementation of the metadata handling engine.
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
# A class to encapsulate metadata context handling. This class provides the
# methods required to manage metadata contexts in the system, including
# creating and removing them, and modifying the reference count in the context
# when roles, tags, courses, resources and so on are added to, or removed from,
# the context.
#
# Metadata contexts are generic containers to which other pieces of data may
# be attached. Usually each context has a parent, and if the parent is undef
# the context is considered to be a root context. Generally there will only be
# a single root in the system - the one corresponding to the front page of the
# site. Contexts also have a reference count, which keeps track of how many
# things have attached themselves to the context - a metadata context can not
# be deleted unless its reference count is zero.
#
# Individual things - roles, tags, etc - need to keep track of which metadata
# context they are attached to, by storing a metadata ID with their data. The
# metadata context itself does not retain a list of attached 'things'.
package WebUI::System::Metadata;

use strict;
use base qw(Webperl::SystemModule);


# ============================================================================
#  Clean shutdown support

## @method void clear()
# A function callable by System to ensure that the 'ondestroy' array does not
# prevent object destruction.
sub clear {
    my $self = shift;

    # Nuke any ondelete entries
    $self -> {"ondestroy"} = [];
}


# ==============================================================================
# Public interface

## @method void register_ondestroy($obj)
# Register a class as needing to have its on_metadata_destroy() function called
# when destroy() removes a metadata context.
#
# @param obj A reference to an object that needs to do cleanup when a context is destroyed.
sub register_ondestroy {
    my $self = shift;
    my $obj  = shift;

    push(@{$self -> {"ondestroy"}}, $obj);
}


## @method $ create($parentid)
# Create a new metadata context with the specified parent ID, and return the ID
# of the newly created context.
#
# @param parentid The ID of this context's parent, or undef to create a root. Note
#                 that root contexts should only be created with the utmost caution,
#                 as they terminate role inheritance hierarchies.
# @return The new metadata context id, or undef on error.
sub create {
    my $self     = shift;
    my $parentid = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                            (parent_id)
                                            VALUES(?)");
    my $rows = $newh -> execute($parentid);
    return $self -> self_error("Unable to perform metadata insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Metadata insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $metadataid = $self -> {"dbh"} -> {"mysql_insertid"};

    # Increment the parent's refcount if addition worked
    $self -> attach($parentid) or return undef
        if($parentid && $metadataid);

    # Return undef if metadataid is undef or zero
    return $metadataid ? $metadataid : undef;
}


## @method $ destroy($metadataid)
# Attempt to delete the specified metadata context from the system. If the refcount for
# the context is non-zero, this will fail with an error. Note that this will not attempt
# to delete any child contexts - they must have been deleted, and detached, before calling
# this function.
#
# @param metadataid The ID of the metadata context to delete.
# @return true on success, undef on error.
sub destroy {
    my $self       = shift;
    my $metadataid = shift;

    $self -> clear_error();

    # Can't do anything without knowing the reference count value
    my $refcount = $self -> _fetch_metadata_refcount($metadataid);
    return undef if(!defined($refcount));

    return $self -> self_error("Attempt to delete metadata context $metadataid with non-zero ($refcount) reference count.")
        if($refcount);

    # Reference count is zero, so nuke the context
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                             WHERE id = ?");
    $nukeh -> execute($metadataid)
        or return $self -> self_error("Metadata context delete failed: ".$self -> {"dbh"} -> errstr);

    # Call any objects that need to do cleanup
    foreach my $obj (@{$self -> {"ondestroy"}}) {
        $obj -> on_metadata_destroy($metadataid) if($obj -> can("on_metadata_destroy"));
    }

    return 1;
}


## @method $ attach($metadataid)
# Attach to the specified metadata context. This increments the specified metadata
# context's reference counter, ensuring that it can not be destroyed until everything
# that references it has detached.
#
# @param metadataid The ID of the metadata context to attach to.
# @return The number of references on success, undef on error.
sub attach {
    my $self = shift;
    my $metadataid = shift;

    return $self -> _update_metadata_refcount($metadataid, 1);
}


## @method $ detach($metadataid, $retain_unused)
# Detach from the specified metadata context. This decrements the specified metadata
# context's reference counter, potentially zeroing it - if this happens, and
# retain_unused has not been set, the metadata context will be deleted.
#
# @param metadataid    The ID of the metadata context to attach to.
# @param retain_unused If true, do not delete the context even if its refcount will
#                      be zero after calling this.
# @return The reference count (which may be zero) on success, false on error.
sub detach {
    my $self          = shift;
    my $metadataid    = shift;
    my $retain_unused = shift;

    # Change the refcount, bomb if the change failed.
    my $result = $self -> _update_metadata_refcount($metadataid, 0);
    return undef if(!defined($result));

    # Nuke the context if there's no reason to keep it around.
    return $self -> destroy($metadataid)
        unless($retain_unused || $result);

    return $result;
}


## @method $ parentid($metadataid)
# Obtain the ID of the specified metadata context's parent. This will look up the
# ID of the parent of the specified metadata context, and return it, potentially
# returning undef if the parent id is NULL - the specified metadata id corresponds
# to the root context. This method will attempt to use the role cache before going
# to the database for the id.
#
# @param metadataid The ID of the metadata context to obtain the parent ID for.
# @return The ID of the metadata context's parent (which may be ""). If an error
#         occurred, this will return undef and the error message will be stored
#         in $self -> {"errstr"}
sub parentid {
    my $self       = shift;
    my $metadataid = shift;

    # Check the cache for the metadata entry, return the parent if it's there...
    return $self -> {"cache"} -> {"metadata"} -> {$metadataid} -> {"parent_id"}
        if(defined($self -> {"cache"} -> {"metadata"} -> {$metadataid} -> {"parent_id"}));

    # Otherwise, fetch the parent
    my $parentid = $self -> _fetch_metadata_parentid($metadataid);
    return undef if(!defined($parentid));

    # Cache the parent
    $self -> {"cache"} -> {"metadata"} -> {$metadataid} -> {"parent_id"} = $parentid;

    return $parentid;
}


## @method $ reparent($metadataid, $newparentid)
# Detatch the specified metadata context from its current parent (if possible) and
# reattach it to a different parent. This will handle ensuring that reference
# counters are changed appropriately, and links are maintained.
#
# @param metadataid The ID of the metadata context to reparent.
# @param newparentid The ID of the metadata context to set as the new parent.
# @return true on success, undef on error.
sub reparent {
    my $self        = shift;
    my $metadataid  = shift;
    my $newparentid = shift;

    my $parentid = $self -> parentid($metadataid);
    return undef if(!defined($parentid));

    my $refcount = $self -> detach($parentid);
    return undef if(!defined($refcount));

    $self -> _set_metadata_parentid($metadataid, $newparentid)
        or return undef;

    $self -> attach($newparentid)
        or return undef;

    return 1;
}


# ==============================================================================
# Private methods


## @method private $ _fetch_metadata_parentid($metadataid)
# Obtain the metadata ID of the parent of the specified metadata context. If the
# metadataid specified corresponds to a root node (one with no parent), this will
# return an empty string.
#
# @param metadataid The ID of the metadata context to find the parent ID for.
# @return The metadata context's parent ID, the empty string if the context has no
#         parent, or undef on error.
sub _fetch_metadata_parentid {
    my $self       = shift;
    my $metadataid = shift;

    $self -> clear_error();

    my $parenth = $self -> {"dbh"} -> prepare("SELECT parent_id FROM ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                               WHERE id = ?");
    $parenth -> execute($metadataid)
        or return $self -> self_error("Unable to perform metadata parent lookup: ". $self -> {"dbh"} -> errstr);

    # This should return something, or the metadataid is invalid
    my $parent = $parenth -> fetchrow_arrayref();
    return $self -> self_error("Unable to find metadata parent: invalid metadataid specified") if(!$parent);

    # Parent is either defined, or undef. If it's undef, return "" instead.
    return $parent -> [0] || "";
}


## @method private $ _fetch_metadata_refcount($metadataid)
# Obtain the reference count for the specified metadata context.
#
# @param metadataid The ID of the metadata context to fetch the refcount for.
# @return The reference count, which may be zero, or undef on error.
sub _fetch_metadata_refcount {
    my $self       = shift;
    my $metadataid = shift;

    $self -> clear_error();

    # Check that the refcount exists, and under/overflow is not going to happen
    my $checkh = $self -> {"dbh"} -> prepare("SELECT refcount FROM ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                              WHERE id = ?");
    $checkh -> execute($metadataid)
        or return $self -> self_error("Metadata lookup failed: ".$self -> {"dbh"} -> errstr);

    my $metadata = $checkh -> fetchrow_arrayref();
    return $self -> self_error("Metadata refcount update failed: unable to locate context $metadataid")
        if(!$metadata);

    return $metadata -> [0];
}


## @method private $ _update_metadata_refcount($metadataid, $increment)
# Increment or decrement the value stored in the specified metadata context's reference
# counter. This is the actual implementation underlying attach() and detach().
#
# @param metadataid The ID of the metadata context to update the refcount for.
# @param increment  If true, the refcount is incremented, otherwise it is decremented.
# @return The new value of the reference count on success (which may be zero), undef on error.
sub _update_metadata_refcount {
    my $self = shift;
    my $metadataid = shift;
    my $increment  = shift;

    $self -> clear_error();

    my $refcount = $self -> _fetch_metadata_refcount($metadataid);
    return undef if(!defined($refcount));

    return $self -> self_error("Metadata refcount update failed: attempt to set refcount for $metadataid out of range (old: $refcount, mode is ".($increment ? "inc)" : "dec)"))
        if((!$increment && $refcount == 0) || ($increment && $refcount == $self -> {"max_refcount"}));

    # Update is safe, do the operation.
    my $atth = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                            SET refcount = refcount ".($increment ? "+" : "-")." 1
                                            WHERE id = ?");
    my $result = $atth -> execute($metadataid);

    # Detect and handle errors
    return $self -> self_error("Unable to update metadata refcount: ".$self -> {"dbh"} -> errstr)
        if(!$result);

    # Detect row change failure, assume bad id
    return $self -> self_error("Metadata refcount update failed: no rows updated. This should not happen!")
        if($result eq "0E0");

    # Work out what the new refcount is and return it
    $refcount = ($increment ? $refcount + 1 : $refcount - 1);
    return $refcount;
}


## @method private $ _set_metadata_parentid($metadataid, $parentid)
# Set the parent ID of the specified metadata context.
#
# @param metadataid The ID of the metadata context to set the parent for.
# @param parentid   The ID of the metadata context's new parent.
# @return true on success, undef on error.
sub _set_metadata_parentid {
    my $self       = shift;
    my $metadataid = shift;
    my $parentid   = shift;

    my $seth = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"metadata"}."
                                            SET parent_id = ?
                                            WHERE id = ?");
    my $result = $seth -> execute($parentid, $metadataid);

    # Detect and handle errors
    return $self -> self_error("Unable to update metadata parent: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Metadata parent update failed: no rows updated. This should not happen!") if($result eq "0E0");

    # Cache the parent
    $self -> {"cache"} -> {"metadata"} -> {$metadataid} -> {"parent_id"} = $parentid;

    return 1;
}

1;
