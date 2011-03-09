## @file
# This file contains the implementation of a form field validation 
# support class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 0.1
# @date    9 Mar 2011
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
# The FormValidators class provides various functions required
# to validate form fields for the course processor web ui.
package FormValidators;

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

## @cmethod FormValidators new(@args)
# Create a new FormValidators object.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new FormValidators object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $obj     = {
        cgi          => undef,
        dbh          => undef,
        settings     => undef,
        template     => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($obj -> {"cgi"});
    return set_error("dbh object not set") unless($obj -> {"dbh"});
    return set_error("settings object not set") unless($obj -> {"settings"});
    return set_error("template object not set") unless($obj -> {"template"});

    return bless $obj, $class;
}


# ============================================================================
#  Validation functions

## @method @ validate_string($sysvars, $param, $settings)
# Determine whether the string in the namedcgi parameter is set, clean it
# up, and apply various tests specified in the settings. The settings are
# stored in a hash, the recognised contents are as below, and all are optional
# unless noted otherwise:
#
# required   - If true, the string must have been given a value in the form.
# default    - The default string to use if the form field is empty. This is not 
#              used if required is set!
# nicename   - The required 'human readable' name of the field to show in errors.
# minlen     - The minimum length of the string.
# maxlen     - The maximum length of the string.
# chartest   - A string containing a regular expression to apply to the string. If this
#              <b>matches the field</b> the validation fails!
# chardesc   - Must be provided if chartest is provided. A description of why matching
#              chartest fails the validation.
# formattest - A string containing a regular expression to apply to the string. If the
#              string <b>does not</b> match the regexp, validation fails.
# formatdesc - Must be provided if formattest is provided. A description of why not
#              matching formattest fails the validation.
#
# @param sysvars  A reference to a hash containing template, cgi, settings, session, and database objects.
# @param param    The name of the cgi parameter to check/
# @param settings A reference to a hash of settings to control the validation 
#                 done to the string.
# @return An array of two values: the first contains the text in the parameter, or
#         as much of it as can be salvaged, while the second contains an error message
#         or undef if the text passes all checks.
sub validate_string {
    my $self  = shift;
    my $param    = shift;
    my $settings = shift;

    # Grab the parameter value, fall back on the default if it hasn't been set.
    my $text = $self -> {"cgi"} -> param($param);

    # Handle the situation where the parameter has not been provided at all
    if(!defined($text) || $text eq '' || (!$text && $settings -> {"nonzero"})) {
        # If the parameter is required, return empty and an error
        if($settings -> {"required"}) {
            return ("", $self -> {"template"} -> replace_langvar("VALIDATE_NOTSET", "", {"***field***" => $settings -> {"nicename"}}));
        # Otherwise fall back on the default.
        } else {
            $text = $settings -> {"default"} || "";
        }
    }
    
    # If there's a test regexp provided, apply it
    my $chartest = $settings -> {"chartest"};
    return ($text, $self -> {"template"} -> replace_langvar("VALIDATE_BADCHARS", "", {"***field***" => $settings -> {"nicename"},
                                                                                      "***desc***"  => $settings -> {"chardesc"}}))
        if($chartest && $text =~ /$chartest/);

    # Is there a format check provided, if so apply it
    my $formattest = $settings -> {"formattest"};
    return ($text, $self -> {"template"} -> replace_langvar("VALIDATE_BADFORMAT", "", {"***field***" => $settings -> {"nicename"},
                                                                                       "***desc***"  => $settings -> {"formatdesc"}}))
        if($formattest && $text !~ /$formattest/);

    # Convert all characters in the string to safe versions
    $text = encode_entities($text);

    # Now trim spaces
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    # Get here and we have /something/ for the parameter. If the maximum length
    # is specified, does the string fit inside it? If not, return as much of the
    # string as is allowed, and an error
    return (substr($text, 0, $settings -> {"maxlen"}), $self -> {"template"} -> replace_langvar("VALIDATE_TOOLONG", "", {"***field***"  => $settings -> {"nicename"},
                                                                                                                         "***maxlen***" => $settings -> {"maxlen"}}))
        if($settings -> {"maxlen"} && length($text) > $settings -> {"maxlen"});

    # Is the string too short (we only need to check if it's required or has content) ? If so, store it and return an error.
    return ($text, $self -> {"template"} -> replace_langvar("VALIDATE_TOOSHORT", "", {"***field***"  => $settings -> {"nicename"},
                                                                                      "***minlen***" => $settings -> {"minlen"}}))
        if(($settings -> {"required"} || length($text)) && $settings -> {"minlen"} && length($text) < $settings -> {"minlen"});

    # Get here and all the tests have been passed or skipped
    return ($text, undef);
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
