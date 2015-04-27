## @file
# This file contains the WebUI-specific implementation of the runtime
# block selection class.
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
# Select the appropriate block to render a page based on an WebUI URL.
# This allows a url of the form /block/item/path/?args to be parsed into
# something the WebUI classes can use to render pages properly, and
# select the appropriate block for the current request.
package WebUI::BlockSelector;

use strict;
use base qw(Webperl::BlockSelector);

# ============================================================================
#  Block Selection

## @method $ get_block($dbh, $cgi, $settings, $logger, $session)
# Determine which block to use to generate the requested page. This performs
# the same task as BlockSelector::get_block(), except that it will also parse
# the contents of the PATH_INFO environment variable into the query string
# data, allowing WebUI paths to be passed to the rest of the code without
# the need to check both the query string and PATH_INFO.
#
# After this has been called, the following variables may be set in the cgi
# object:
#
# - `block` contains the currently selected block name, or the gallery block name
#   if one has not been specified.
# - `pathinfo` contains the path to the currently selected item, as an array
#   of path segments. If not set, no item has been selected. Note that
#   this is simply a split version of any path info between the block and any
#   api specification, so it may be used by blocks to mean something other than
#   the item selected if needed.
# - `pathinfo` contains any API call data, if any, as an array of path items.
#   If this is set, the first item will be the literal `api`, while the remaining
#   items will be the API operation and arguments.
#
# @param dbh      A reference to the database handle to issue queries through.
# @param cgi      A reference to the system CGI object.
# @param settings A reference to the global settings object.
# @param logger   A reference to the system logger object.
# @param session  A reference to the session object.
# @return The id or name of the block to use to render the page, or undef if
#         an error occurred while selecting the block.
sub get_block {
    my $self     = shift;
    my $dbh      = shift;
    my $cgi      = shift;
    my $settings = shift;
    my $logger   = shift;
    my $session  = shift;

    $self -> self_error("");

    my $pathinfo = $ENV{'PATH_INFO'};

    # If path info is present, it needs to be shoved into the cgi object
    if($pathinfo) {
        # strip off the script if it is present
        $pathinfo =~ s|^(/media)?/index.cgi||;

        # pull out the api if specified
        my ($apicall) = $pathinfo =~ m|/(api.*)$|;
        $pathinfo =~ s|/api.*|| if($apicall);

        # No need for leading /, it'll just confuse the split
        $pathinfo =~ s|^/||;

        # Split along slashes
        my @args = split(/\//, $pathinfo);

        # Defaults the block to the gallery, and clear the pathinfo and pathinfo for safety
        my $block = $settings -> {"config"} -> {"gallery_block"};
        $cgi -> delete('pathinfo', 'api');

        # If a single item remains in the argument, it is a block name
        if(scalar(@args) == 1) {
            $block = shift @args;

        # Two or more items in the argument are a block and item path
        } elsif(scalar(@args) >= 2) {
            $block = shift @args;
            $cgi -> param(-name => 'pathinfo', -values => \@args);
        }

        $cgi -> param(-name => 'block', -value => $block);

        # Now sort out the API
        if($apicall) {
            my @api = split(/\//, $apicall);
            $cgi -> param(-name => 'api', -values => \@api);
        }
    }

    # The behaviour of BlockSelector::get_block() is fine, so let it work out the block
    return $self -> SUPER::get_block($dbh, $cgi, $settings, $logger);
}

1;
