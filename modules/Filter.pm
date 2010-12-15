# @file
# This file contains the implementation of the course processor filtering
# system.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    4 Nov 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
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

## @class Filter
# This class provides an implementation of the filtering system described
# in the APEcs development wiki on the following page:
#
# http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Course_design_issues#Content_filtering
#
# The core function is the filter() function that actually applies the
# rules discussed on that page, in summary:
#
# - resources that have no <filters> element in their metadata will always be included.
# - if no filters are selected on the command line, all resources that have no <filters>,
#   or only exclusionary filters (ie: the <filters> element contains no <include> elements)
#   will be included. 
# - if one or more filters are selected, all resources with no <filters> are included, as
#   are resources with <include> elements that match one of the selected filters. Any 
#   resources that have matching <exclude> elements will be excluded, even if they have
#   matching <include> elements (ie: exclude takes precedent over include)

package Filter;

use strict;

our ($VERSION, $errstr);

BEGIN {
	$VERSION = 1.0;
	$errstr = '';
}

# ============================================================================
#  Constructor function

## @cmethod $ new($filterdata)
# Create a new Filter object. This creates an object that provides functions
# for determining whether to include a resource in a generated course.
#
# @param filterdata Either a string of comma separated filter names, a reference
#                   to an array of filter names (which may themselves be CSV),
#                   or undef or '' to indicate that no filtering is needed.
# @return A new Filter object, or undef if a problem occured.
sub new {
    my $invocant   = shift;
    my $class      = ref($invocant) || $invocant;
    my $filterdata = shift;

    # Object constructors don't get much more minimal than this...
    my $self = { "filters" => { } };
    my $obj = bless $self, $class;

    # Return here if we have no filters to work with
    return $obj if(!$filterdata);

    # If the filters element is an arrayref, convert it to a string, otherwise just use it as a string...
    my $filtertemp = ref($filterdata) ? join(',', $filterdata) : $filterdata;

    # Split and enhashinate
    my @filters = split(/,/, $filtertemp);
    my $filterhash;
    foreach my $filter (@filters) {
        # Store the filter forced to lowercase so that we don't need to 
        # worry about case issues when filtering...
        $obj -> {"filters"} -> {lc($filter)} = 1;
    }

    return $obj;
}


# ============================================================================
#  Filter logic

## @method $ filter($resource)
# Determine whether the resource identified by the provided metadata fragment should
# be included in the generated content. This will check the specified resource 
# metadata to determine whether it has any filters set, and if it has it will apply
# the filtering rules to it to establish whether it should be included in the 
# generated content.
#
# @param resource A reference to the resource's metadata fragment.
# @return true if the resource should be included, false if it should be excluded.
sub filter {
    my $self     = shift;
    my $resource = shift;

    # Resources with no 'filters' will always be included
    return 1 if(!$resource -> {"filters"});

    # if we have no filters set in the config, include the resource as long as
    # it has no include elements.
    return 1 if(keys(%{$self -> {"filters"}}) == 0 && !$resource -> {"filters"} -> {"include"});

    # if we have any exclude filters, do any match the system filters?
    foreach my $exclude (@{$resource -> {"filters"} -> {"exclude"}}) {
        next if(ref($exclude)); # It's possible that exclude is not a string here - skip it if so!

        # Simple hash lookup against the filters hash to determine whether the exclude matches.
        # Does a lowercase match to avoid case issues.
        return 0 if($self -> {"filters"} -> {lc($exclude)});
    }

    # If we get here, either the resource has no excludes, or none of them match filters
    # set by the user. If there are no includes, we should include the resource
    return 1 if(!$resource -> {"filters"} -> {"include"});

    # None of the excludes match (or we have no excludes), so do any of the includes match?
    foreach my $include (@{$resource -> {"filters"} -> {"include"}}) {
        next if(ref($include)); # again, this may not be a string, so skip it if it's a reference

        return 1 if($self -> {"filters"} -> {lc($include)});
    }

    # Get here and we have one or more includes, but none matched.
    return 0;
}


## @method $ include_resource($resource)
# Convenience and readability function to wrap the filter() method. This will return
# true if the resource should be included in the generated course, and false if it
# should not be included.
#
# @param resource A reference to the resource's metadata fragment.
# @return true if the resource should be included, false if it should be excluded.
sub include_resource {
    my $self     = shift;
    my $resource = shift;

    return $self -> filter($resource);
}


## @method $ exclude_resource($resource)
# Convenience and readability function to wrap the filter() method. This will return
# true if the resource *SHOULD NOT* be included in the course, and false if it should
# be included. This is the logical inverse of the include_resource() method.
#
# @param resource A reference to the resource's metadata fragment.
# @return true if the resource should be included, false if it should be excluded.
sub exclude_resource {
    my $self     = shift;
    my $resource = shift;

    return !$self -> filter($resource);
}


## @method $ includes_filter($resource)
# A special filtering function needed to support filtering of resources in theme
# include blocks. This performs the same include/exclude calculation as filter(),
# except that it assumes the filters will be specified as comma separated values
# stored in 'include' and 'exclude' keys in the provided resource hash.
#
# @param resource A reference to the hash containing the include resource metadata.
# @return true if the resource should be included, false otherwise.
sub includes_filter {
    my $self     = shift;
    my $resource = shift;

    # If we have no include or exclude set on the resource, it is always included
    return 1 if(!$resource -> {"include"} && !$resource -> {"exclude"});

    # if we have no filters set in the config, include the resource as long as
    # it has no include elements.
    return 1 if(keys(%{$self -> {"filters"}}) == 0 && !$resource -> {"include"});

    # Do we have any exclude filters set? If so, check whether one matches the
    # filters set by the user.
    if($resource -> {"exclude"}) {
        # split the excludes up
        my @excludes = split(/,/, $resource -> {"exclude"});

        # Check whether the excludes have been set by the user
        foreach my $exclude (@excludes) {
            return 0 if($self -> {"filters"} -> {lc($exclude)});
        }
    }

    # If we get here, either the resource has no excludes, or none of them match filters
    # set by the user. If there are no includes, we should include the resource
    return 1 if(!$resource -> {"include"});

    # no excludes have been set, or at least none match, and we have includes so process them.
    my @includes = split(/,/, $resource -> {"include"});

    # do any includes match?
    foreach my $include (@includes) {
        return 1 if($self -> {"filters"} -> {lc($include)});
    }
    
    # Get here and we have one or more includes but none of them match, so we don't include
    return 0;
}

1;
