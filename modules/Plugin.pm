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

# ============================================================================
#  Plugin class required functions
#   

## @cmethod $ new(%args)
# Create a new plugin object. This will intialise the plugin to a base state suitable
# for use by the processor. The following arguments may be provided to this constructor:
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
# @return true to indicate processing was successful, false otherwise.
sub process {
    my $self = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Direct call to base Plugin::process. Derived class is not overriding this function.");
    return 0;
}


# ============================================================================
#  Plugin utility functions (would be in Utils except need for access to $self)
#   


1;
