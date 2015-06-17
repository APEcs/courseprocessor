## @file
# This file contains the WebUI-specific implementation of the runtime
# application-specific module loader class.
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
# Loads any system-wide application specific modules needed by the
# WebUI application.
package WebUI::System;

use strict;
use base qw(Webperl::System);

use WebUI::System::Metadata;
use WebUI::System::Roles;
use WebUI::System::Tags;

## @method $ init(%args)
# Initialise the WebUI System's references to other system objects. This
# sets up the WebUI-specific modules, placing references to them into the
# object's hash. The argument hash provided must minimally contain the
# following references:
#
# * cgi, a reference to a CGI object.
# * dbh, a reference to the DBI object to issue database queries through.
# * settings, a reference to the global settings object.
# * logger, a reference to a Logger object.
# * template, a reference to the system template engine.
# * session, a reference to the system session handler.
# * modules, a reference to the module loader.
#
# @param args A hash of arguments to initialise the System object with.
# @return true on success, false if something failed. If this returns false,
#         the reason is in $self -> {"errstr"}.
sub init {
    my $self   = shift;

    # Let the superclass copy the references over
    $self -> SUPER::init(@_)
        or return undef;

    # now create the WebUI-specific objects
    $self -> {"metadata"} = WebUI::System::Metadata -> new(dbh      => $self -> {"dbh"},
                                                             settings => $self -> {"settings"},
                                                             logger   => $self -> {"logger"})
        or return $self -> self_error("Metadata system init failed: ".$Webperl::SystemModule::errstr);

    $self -> {"roles"} = WebUI::System::Roles -> new(dbh      => $self -> {"dbh"},
                                                       settings => $self -> {"settings"},
                                                       logger   => $self -> {"logger"},
                                                       metadata => $self -> {"metadata"})
        or return $self -> self_error("Roles system init failed: ".$Webperl::SystemModule::errstr);

    return 1;
}

1;
