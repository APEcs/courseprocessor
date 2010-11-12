## @file
# This file contains the implementation of the base plugin class for the
# course processor
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    11 Nov 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
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

## @class Plugin
# All input and output plugins in the course processor must extend this
# class and provide appropriate implementations for marked functions.
#
package Plugin;

use strict;
use File::Path;

# ============================================================================
#  Plugin class required functions. These will usually be overridden/extended
#  in derived classes.
#   

## @cmethod $ new(%args)
# Create a new plugin object. This will intialise the plugin to a base state suitable
# for use by the processor. This function does not NEED to be overridden in any
# derived classes, but it usually will be so that the derived class can set its own
# configuration defaults if necessary. The following arguments may be provided to 
# this constructor:
#
# config     (required) A reference to the global configuration object.
# logger     (required) A reference to the global logger object.
# path       (required) The directory containing the processor
# metadata   (required) A reference to the metadata handler object.
# template   (required) A reference to the template engine object.
#
# @param args A hash of arguments to initialise the plugin with. 
# @return A new Plugin object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = { @_, };

    return bless $self, $class;
}


## @method $ use_plugin()
# Determine whether this plugin should be run against the source tree by looking for
# files it recognises how to process in the directory structure. This will scan 
# through the directory structure of the source and count how many files it thinks
# the plugin should be able to process, and returns this count. If this is 0, the
# plugin can not be used on the source tree.
#
# @note Derived classes MUST override this function to provide the appropriate
#       behaviour. If this function is called directly it will create an warning.
#
# @return The number of files in the source tree that the plugin can process, 0
#         indicates that the plugin can not run on the source tree.
sub use_plugin {
    my $self = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Direct call to base Plugin::use_plugin. Derived class is not overriding this function.");
    return 0;
}


# @method $ module_check($themedir, $module)
# Check whether the module specified is valid and usable by this plugin. This is
# used by the metadata validation code to determine whether the module specified
# appears to be valid. This will return a string containing an error message if 
# there is a problem, 0 otherwise.
#
# @note Derived classes MUST override this function to provide the appropriate
#       behaviour. If this function is called directly it will create an warning.
# @note This function is only needed within input plugins, it is never called on
#       output plugins.
#
# @param themedir The directory containing the module to check.
# @param module   The name of the module to check.
# @return 0 if the module is valid, an error string otherwise.
sub module_check {
    my $self = shift;

    return "Direct call to base Plugin::module_check. Derived class is not overriding this function.";
}


## @method $ process()
# Run the plugin over the contents of the course data. This should be overridded to
# perform plugin-specific operations on the course data in accordance with the
# purpose of the plugin.
#
# @note Derived classes MUST override this function to provide the appropriate
#       behaviour. If this function is called directly it will create an warning.
#
# @return true to indicate processing was successful, false otherwise.
sub process {
    my $self = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Direct call to base Plugin::process. Derived class is not overriding this function.");
    return 0;
}


# ============================================================================
#  Plugin convenience functions. Should not be overridden, here mainly for
#  readability

## @method $ get_type()
# Obtain the plugin's type string. This will return a string that identifies 
# the plugin as either an 'input' plugin, and 'output' plugin, or potentially
# 'reference' plugin.
#
# @return The plugin type string.
sub get_type {
    my $self = shift;

    return $self -> {"htype"};
}


## @method $ get_description()
# Obtain the plugin's descriptive string. This will return a string describing
# the plugin in a human-readable format.
sub get_description {
    my $self = shift;

    return $self -> {"description"};
}


# ============================================================================
#  Plugin utility functions (would be in Utils except need for access to $self)
#  These should generally not be overridden in derived classes.

## @method $ makedir($name, $no_warn_exists)
# Attempt to create the specified directory if needed. This will determine
# whether the directory exists, and if not whether it can be created.
#
# @param name           The name of the directory to create.
# @param no_warn_exists If true, no warning is generated if the directory exists.
# @return true if the directory was created, false otherwise.
sub makedir {
    my $self           = shift;
    my $name           = shift;
    my $no_warn_exists = shift;

    # If the directory exists, we're okayish...
    if(-d $name) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Dir $name exists, the contents will be overwritten.")
            unless($quiet || $no_warn_exists);
        return 1;

    # It's not a directory, is it something... else?
    } elsif(-e $name) {
        # It exists, and it's not a directory, so we have a problem
        die "FATAL: dir $name corresponds to a file or other resource.\n";

    # Okay, it doesn't exist in any form, time to make it
    } else {
        eval { mkpath($name); };

        if($@) {
            die "FATAL: Unable to create directory $name: $@\n";
        }
        return 1;
    }

    return 0;
}

1;
