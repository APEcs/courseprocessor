## @file
# This file contains the implementation of the tag handling engine.
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
# This class encapsulates operations involving tags in the system.
package WebUI::System::Tags;

use strict;
use base qw(Webperl::SystemModule);

# ==============================================================================
#  Creation

## @cmethod $ new(%args)
# Create a new Tags object to manage tag allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Tags object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # Check that the required objects are present
    return Webperl::SystemModule::set_error("No metadata object available.") if(!$self -> {"metadata"});

    # Register with the metadata destroy handler
    $self -> {"metadata"} -> register_ondestroy($self);

    return $self;
}


# ============================================================================
#  Public interface - tag creation, deletion, etc

## @method $ create($name, $userid)
# Create a new tag with the specified name. This will create a new tag, setting
# its name and creator to the values specified. Note that this will not check
# whether a tag with the same name already exists
#
# @param name   The name of the tag to add.
# @param userid The ID of the user creating the tag.
# @return The new tag ID on success, undef on error.
sub create {
    my $self   = shift;
    my $name   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                            (name, creator_id, created)
                                            VALUES(?, ?, UNIX_TIMESTAMP())");
    my $rows = $newh -> execute($name, $userid);
    return $self -> self_error("Unable to perform tag insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Tag insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $tagid = $self -> {"dbh"} -> {"mysql_insertid"};
    return $self -> self_error("Unable to obtain id for tag '$name'") if(!$tagid);

    return $tagid;
}


## @method $ destroy($tagid)
# Attempt to remove the specified tag, and any assignments of it, from the system.
#
# @warning This will remove the tag, any tag assignments, and any active flags for the
#          tag. It will work even if there are resources currently tagged with this tag.
#          Use with extreme caution!
#
# @param tagid The ID of the tag to remove from the system
# @return true on success, undef on error
sub destroy {
    my $self  = shift;
    my $tagid = shift;

    $self -> clear_error();

    # Delete any tag assignments first. This is utterly indiscriminate, if this breaks
    # something important, don't say I didn't warn you.
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                             WHERE tag_id = ?");
    $nukeh -> execute($tagid)
        or return $self -> self_error("Unable to perform tag allocation removal: ". $self -> {"dbh"} -> errstr);

    # Delete any activations of this tag
    $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"active_tags"}."
                                          WHERE tag_id = ?");
    $nukeh -> execute($tagid)
        or return $self -> self_error("Unable to perform active tag removal: ". $self -> {"dbh"} -> errstr);

    # And now delete the tag itself
    $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                          WHERE id = ?");
    $nukeh -> execute($tagid)
        or return $self -> self_error("Unable to perform tag removal: ". $self -> {"dbh"} -> errstr);

    return 1;
}


## @method $ get_tagid($name, $userid)
# Obtain the ID associated with the specified tag. If the tag does not yet exist
# in the tags table, this will create it and return the ID the new row was
# allocated.
#
# @param name   The name of the tag to obtain the ID for
# @param userid The ID of the user requesting the tag, in case it must be created.
# @return The ID of the tag on success, undef on error.
sub get_tagid {
    my $self   = shift;
    my $name   = shift;
    my $userid = shift;

    # Search for a tag with the specified name, give up if an error occurred
    my $tagid = $self -> _fetch_tagid($name);
    return $tagid if($tagid || $self -> {"errstr"});

    # Get here and the tag doesn't exist, create it
    return $self -> create($name, $userid);
}


## @method $ attach($metadataid, $tagid, $userid, $persist, $rating)
# Attach a tag to a metadata context. This will attempt to apply the specified tag
# to the metadata context, recording the user that requested the attachment.
#
# @param metadataid The ID of the metadata context to attach the tag to.
# @param tagid      The ID of the tag to attach.
# @param userid     The ID of the user responsible for attaching the tag.
# @param rating     Optional initial rating to give the tag. If not specified, this
#                   will default to "default_rating" in the configuration.
# @return true on success, undef on error.
sub attach {
    my $self = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;
    my $rating     = shift || $self -> {"settings"} -> {"config"} -> {"default_rating"} || 0;

    $self -> clear_error();

    # determine whether the tag is already set on this metadata context
    my $tag = $self -> _attached($metadataid, $tagid);
    return undef if(!defined($tag));

    # Tag is already set, return true, but log it as it shouldn't really happen
    if($tag) {
        $self -> {"logger"} -> log("warning", $userid, undef, "Attempt to re-set tag $tagid on metadata $metadataid by $userid.");
        return 1;
    }

    # Tag is not set, so add it
    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                            (metadata_id, tag_id, attached_by, attached_date, rating)
                                            VALUES(?, ?, ?, UNIX_TIMESTAMP(), ?)");
    my $rows = $newh -> execute($metadataid, $tagid, $userid, $rating);
    return $self -> self_error("Unable to perform metadata tag insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Metadata tag insert failed: no rows modified") if($rows eq "0E0");

    # Tag has been set, what is the ID of the newly added metadata tag relation?
    my $relation = $self -> {"dbh"} -> {"mysql_insertid"};
    return $self -> self_error("Unable to obtain id for metadata tag relation '$tagid' on '$metadataid'") if(!$relation);

    # Attach to the metadata context
    my $attached = $self -> {"metadata"} -> attach($metadataid);
    return undef if(!$attached); # this should always be 1 or greater if the attach worked.

    # And log the tagging operation in the history
    return $self -> _log_action($metadataid, $tagid, "added", $userid, $rating);
}


## @method $ get_attached_tags($metadataid, $alphasort)
# Generate a list of tags attached to the specified metadata context. This will create
# a list containing reference to tag data hashes, and return a reference to it. If there
# are no tags attached to the context, this returns a reference to an empty list.
#
# @note This will not fetch tags attached to parent contexts: only tags attached to the
#       current context are returned. If your code needs to inherit from the parent, you
#       will need to call this on the parent context and merge the arrays yourself.
#
# @param metadataid The ID of the metadata context to fetch the tags for.
# @param alphasort  If true, sort the list alphanumerically. If this is false, the list
#                   is sorted by rating (highest first), and then alphanumerically.
# @return A reference to an array of tag data hashes (which may be empty) on success,
#         undef if an error occurred.
sub get_attached_tags {
    my $self       = shift;
    my $metadataid = shift;
    my $alphasort  = shift;

    # Tag lookup query, pretty simple...
    my $tagh = $self -> {"dbh"} -> prepare("SELECT m.*,t.name,t.creator_id,t.created
                                            FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}." AS m,
                                                 ".$self -> {"settings"} -> {"database"} -> {"tags"}." AS t
                                            WHERE t.id = m.tag_id
                                            AND m.metadata_id = ?
                                            ORDER BY ".($alphasort ? "t.name ASC, m.rating DESC" : "m.rating DESC, t.name ASC"));
    $tagh -> execute($metadataid)
        or $self -> self_error("Unable to perform tag lookup query: ".$self -> {"dbh"} -> errstr);

    # Get the results as a reference to an array of hash refs.
    return $tagh -> fetchall_arrayref({});
}


## @method $ detach($metadataid, $tagid, $userid)
# Remove the tag from the specified metadata context. This will do nothing if the tag is
# not attached to the context, returning true if the tag is not set on the context (but
# potentially logging the attempt as a warning). No permission checks are (or can be) done
# by this method: the caller is required to ensure that the user performing the tag
# removal has permission to do so.
#
# @param metadataid The ID of the metadata context to remove the tag from.
# @param tagid      The ID of the tag to remove.
# @param userid     The ID of the user doing the removal.
# @return true on success (tag is no longer attached, or never was), under on error.
sub detach {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;

    my $tagdata = $self -> _fetch_attached_tag($metadataid, $tagid);
    return undef if($self -> {"errstr"}); # Was an error encountered in the fetch?

    # No need to do anything if the tag is not attached, but log it as an error anyway
    if(!$tagdata) {
        $self -> {"logger"} -> log("warning", $userid, undef, "Attempt to remove unattached tag $tagid from metadata $metadataid by $userid.");
        return 1;
    }

    # Tag is set, so remove it
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                             WHERE metadata_id = ?
                                             AND tag_id = ?");
    my $rows = $nukeh -> execute($metadataid, $tagid);
    return $self -> self_error("Unable to perform metadata tag removal: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Metadata tag removal failed: no rows modified") if($rows eq "0E0");

    # Tag is gone, log the removal
    $self -> _log_action($metadataid, $tagid, "delete", $userid, $tagdata -> {"rating"});

    # Detach from the context
    return defined($self -> {"metadata"} -> detach($metadataid));
}


## @method $ rate_up($metadataid, $tagid, $userid)
# Rate up the specified tag in the metadata context, marking the provided user as the
# person doing the rating. Note that this will not do any permission checking - the
# caller must have established that the user has permission to update the rating.
#
# @param metadataid The ID of the metadata context containing the tag to rate.
# @param tagid      The ID of the tag to change the rating of.
# @param userid     The ID of the user performing the rating change.
# @return true on success, undef on error.
sub rate_up {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;

    return $self -> _update_rating($metadataid, $tagid, $userid, 1);
}


## @method $ rate_down($metadataid, $tagid, $userid)
# Rate down the specified tag in the metadata context, marking the provided user as the
# person doing the rating. Note that this will not do any permission checking - the
# caller must have established that the user has permission to update the rating.
#
# @param metadataid The ID of the metadata context containing the tag to rate.
# @param tagid      The ID of the tag to change the rating of.
# @param userid     The ID of the user performing the rating change.
# @return true on success, undef on error.
sub rate_down {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;

    return $self -> _update_rating($metadataid, $tagid, $userid, 0);
}


## @method $ user_has_rated($metadataid, $tagid, $userid)
# Determine whether the user has rated the specified tag in the metadata context. Note that
# this counts adding a tag as rating it - ie: users who added a tag automatically rate it as
# the default rating. This will only check as far back as the addition of a tag, if a tag has
# been added to a context, rated by a user, and then deleted and re-added, the user is not
# counted as having rated it (that is, this only checks the latest attachement of a tag).
#
# @param metadataid The ID of the metadata context to check for tag ratings.
# @param tagid      The ID of the tag to look for ratings of.
# @param userid     The ID of the user to look for when checking ratings.
# @return true if the user has rated the tag, false otherwise, and undef on error.
sub user_has_rated {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;

    # Fetch the history of the tag, sorted in descending chronological order
    # (ie: latest change first) filtered on the user's id or addition events.
    # This will mean that the first row fetched is either a rating change by
    # the user, or an addition event (possibly also by the user), so only one
    # row is needed to determine whether the user has rated the tag.
    my $histh = $self -> {"dbh"} -> prepare("SELECT user_id FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags_log"}."
                                             WHERE metadata_id = ?
                                             AND tag_id = ?
                                             AND (user_id = ? OR event = 'added')
                                             ORDER BY event_time DESC
                                             LIMIT 1");
    $histh -> execute($metadataid, $tagid, $userid)
        or return $self -> self_error("Unable to perform rating check query: ".$self -> {"dbh"} -> errstr);

    # If there's no row here, something has gone Badly Wrong (probably the tag isn't attached)
    my $histrow = $histh -> fetchrow_arrayref();
    return $self -> self_error("Unexpected empty result from rating check query: no history for $tagid in $metadataid?")
        if(!$histrow);

    # If the user_id in the fetched row matches $userid, the user has rated the
    # tag implicitly (by adding it) or explicitly (by up/down rating it)
    return ($histrow -> [0] == $userid);
}


# ============================================================================
#  Private functions

## @method private $ _attached($metadataid, $tagid)
# Determine whether the specified tag is set in the metadata context. This will check
# whether the tag has been attached to the specified context, and return true if it is.
#
# @param metadataid The ID of the metadata context to check for the tag.
# @param tagid      The ID of the tag to look for.
# @return true if the tag is attached to the context, false if it is not, and undef on error.
sub _attached {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;

    $self -> clear_error();

    my $tagh = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                            WHERE metadata_id = ?
                                            AND tag_id = ?");
    $tagh -> execute($metadataid, $tagid)
        or return $self -> self_error("Unable to execute metadata tag lookup: ".$self -> {"dbh"} -> errstr);

    my $tag = $tagh -> fetchrow_arrayref();
    return defined($tag);
}


## @method private $ _fetch_attached_tag($metadataid, $tagid)
# Obtain the attachment data for the specified tag on a metadata context. This attempts to
# fetch the data associated with an attached tag - who attached it, when, what its current
# rating is - and returns a reference to a hash containing that data.
#
# @param metadataid The ID of the metadata context to check for the tag.
# @param tagid      The ID of the tag to look for.
# @return A reference to a hash containing the attached tag's data, or undef if the tag is
#         not attached, or on error.
sub _fetch_attached_tag {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;

    $self -> clear_error();

    my $tagh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                            WHERE metadata_id = ?
                                            AND tag_id = ?");
    $tagh -> execute($metadataid, $tagid)
        or return $self -> self_error("Unable to execute metadata tag lookup: ".$self -> {"dbh"} -> errstr);

    return $tagh -> fetchrow_hashref();
}


## @method private $ _fetch_tagid($name)
# Given a tag name, attempt to find a tag record for that name. This will locate the
# first defined tag whose name matches the provided name. Note that if there are
# duplicate tags in the system, this will never find duplicates - it is guaranteed to
# find the tag with the lowest ID whose name matches the provided value, or nothing.
#
# @param name The name of the tag to find.
# @return The ID of the tag with the specified name on success, undef if the tag
#         does not exist or an error occurred.
sub _fetch_tagid {
    my $self = shift;
    my $name = shift;

    $self -> clear_error();

    # Does the tag already exist
    my $tagid  = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                              WHERE name LIKE ?");
    $tagid -> execute($name)
        or return $self -> self_error("Unable to perform tag lookup: ".$self -> {"dbh"} -> errstr);
    my $tagrow = $tagid -> fetchrow_arrayref();

    # Return the ID if found, undef otherwise
    return $tagrow ? $tagrow -> [0] : undef;;
}


## @method private $ _update_rating($metadataid, $tagid, $userid, $increment)
# Update the rating for the tag in the specified metadata context. This increments or
# decrements the rating for the tag, marking the specified user as the user doing the
# rating change. Note that this does not (and can not) perform any permission checking:
# the caller must ensure that the user has permission to rate the tag.
#
# @param metadataid The ID of the metadata context containing the tag to rate.
# @param tagid      The ID of the tag to change the rating of.
# @param userid     The ID of the user performing the rating change.
# @param increment  If true, the rating is incremented, otherwise it is decremented.
# @return true on success, undef otherwise.
sub _update_rating {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $userid     = shift;
    my $increment  = shift;

    $self -> clear_error();

    # Get the tag, which will include the current rating and confirm the tag is attached...
    my $tag = $self -> _fetch_attached_tag($metadataid, $tagid);
    return undef if($self -> {"errstr"}); # Was an error encountered in the fetch?
    return $self -> self_error("Unable to update rating for $tagid in $metadataid: tag is not attached|") if(!$tag);

    # Got a tag, update the rating
    $tag -> {"rating"} += ($increment ? 1 : -1);

    my $rateh = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"metadata_tags"}."
                                             SET rating = ?
                                             WHERE id = ?");
    my $rows = $rateh -> execute($tag -> {"rating"}, $tag -> {"id"});
    return $self -> self_error("Unable to perform rating update: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Rating update failed: no rows modified") if($rows eq "0E0");

    # Rating has been updated, log the update
    return $self -> _log_action($metadataid, $tagid, "rate ".($increment ? "up" : "down"), $userid, $tag -> {"rating"});
}


## @method private $ _log_action($metadataid, $tagid, $event, $userid, $rating)
# Log an action on an attached (or newly detached) tag. This allows the history of a tag
# to be tracked over its lifetime of attachment to a resource.
#
# @param metadataid The ID of the metadata the event happened in.
# @param tagid      The ID of the tag involved in the event.
# @param event      The event to be logged, must be 'added', 'deleted', 'rate up',
#                   'rate down', 'activate', or 'deactivate'.
# @param userid     The ID of the user who caused the event.
# @param rating     The rating set on the tag after the operation.
# @return true on success, undef on error.
sub _log_action {
    my $self       = shift;
    my $metadataid = shift;
    my $tagid      = shift;
    my $event      = shift;
    my $userid     = shift;
    my $rating     = shift;

    $self -> clear_error();

    my $acth = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"metadata_tags_log"}."
                                            (metadata_id, tag_id, event, event_user, event_time, rating)
                                            VALUES(?, ?, ?, ?, UNIX_TIMESTAMP(), ?)");
    my $rows = $acth -> execute($metadataid, $tagid, $event, $userid, $rating);
    return $self -> self_error("Unable to perform metadata tag log insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Metadata tag log insert failed: no rows modified") if($rows eq "0E0");

    return 1;
}

1;
