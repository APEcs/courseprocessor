## @file
# This file contains the implementation of the processor view/controller facility.
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
# along with this program.  If not, see http://www.gnu.org/licenses/.

## @class
# A 'stand alone' login implementation. This presents the user with a
# login form, checks the credentials they enter, and then redirects
# them back to the task they were performing that required a login.
package WebUI::Processor;

use strict;
use experimental qw(smartmatch);
use base qw(WebUI); # This class extends the WebUI block class
use Webperl::Utils qw(path_join is_defined_numeric);
use v5.12;

# IDs of the stages
use constant STAGE_WELCOME => 0;
use constant STAGE_COURSE  => 1;
use constant STAGE_EXPORT  => 2;
use constant STAGE_PROCESS => 3;
use constant STAGE_FINISH  => 4;

## @cmethod $ new(%args)
# Overloaded constructor for the Processor, loads the other classes
# required to invoke and control the processor.
#
# @param args A hash of values to initialise the object with. See the Block docs
#             for more information.
# @return A reference to a new WebUI::Processor object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    $self -> {"stages"} = [ # STAGE_WELCOME
                            { "active"   => "templates/default/images/stages/welcome_active.png",
                              "inactive" => "templates/default/images/stages/welcome_inactive.png",
                              "passed"   => "templates/default/images/stages/welcome_passed.png",
                              "width"    => 80,
                              "height"   => 40,
                              "alt"      => "{L_STAGE_WELCOME_STAGETITLE}",
                              "icon"     => "welcome",
                              "func"     => \&_build_stage0_welcome
                            },

                            # STAGE_COURSE
                            { "active"   => "templates/default/images/stages/course_active.png",
                              "inactive" => "templates/default/images/stages/course_inactive.png",
                              "passed"   => "templates/default/images/stages/course_passed.png",
                              "width"    => 80,
                              "height"   => 40,
                              "alt"      => "{L_STAGE_COURSE_STAGETITLE}",
                              "icon"     => "course",
                              "hasback"  => 1,
                              "func"     => \&_build_stage1_course
                            },

                            # STAGE_EXPORT
                            { "active"   => "templates/default/images/stages/export_active.png",
                              "inactive" => "templates/default/images/stages/export_inactive.png",
                              "passed"   => "templates/default/images/stages/export_passed.png",
                              "width"    => 80,
                              "height"   => 40,
                              "alt"      => "{L_STAGE_EXPORT_STAGETITLE}",
                              "icon"     => "export",
                              "hasback"  => 1,
                              "func"     => \&_build_stage2_export
                            },

                            # STAGE_PROCESS
                            { "active"   => "templates/default/images/stages/process_active.png",
                              "inactive" => "templates/default/images/stages/process_inactive.png",
                              "passed"   => "templates/default/images/stages/process_passed.png",
                              "width"    => 80,
                              "height"   => 40,
                              "alt"      => "{L_STAGE_PROCESS_STAGETITLE}",
                              "icon"     => "process",
                              "hasback"  => 1,
                              "func"     => \&_build_stage3_process
                            },

                            # STAGE_FINISH
                            { "active"   => "templates/default/images/stages/finish_active.png",
                              "inactive" => "templates/default/images/stages/finish_inactive.png",
                              "passed"   => "templates/default/images/stages/finish_passed.png",
                              "width"    => 80,
                              "height"   => 40,
                              "alt"      => "{L_STAGE_FINISH_STAGETITLE}",
                              "icon"     => "finish",
                              "hasback"  => 1,
                              "func"     => \&_build_stage4_finish
                            }
        ];

    return $self;
}


# ============================================================================
#  Wizard interface functions

## @method @ _build_stage0_welcome()
# Generate the first stage of the wizard - a simple page describing the application
# and the process.
#
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub _build_stage0_welcome {
    my $self = shift;

    # All we need to do here is generate the title and message...
    my $title    = $self -> {"template"} -> replace_langvar("STAGE_WELCOME_TITLE");
    my $message  = $self -> {"template"} -> wizard_box($self -> {"template"} -> replace_langvar("STAGE_WELCOME_TITLE"),
                                                       $self -> {"stages"} -> [STAGE_WELCOME] -> {"icon"},
                                                       $self -> {"stages"},
                                                       STAGE_WELCOME,
                                                       $self -> {"template"} -> replace_langvar("STAGE_WELCOME_LONGDESC"),
                                                       $self -> {"template"} -> load_template("stages/stage0form.tem"));
    return ($title, $message);
}


## @method @ _build_stage1_course()
# Generate the second stage of the wizard, from which the user can select a
# wiki and a course to process.
#
# @return An array of two values: the title of the page, and the messagebox to show on the page.
sub _build_stage1_course {
    my $self = shift;

    my $additional = $self -> {"template"} -> load_template("stages/stage1form.tem");

    my $title    = $self -> {"template"} -> replace_langvar("STAGE_COURSE_TITLE");
    my $message  = $self -> {"template"} -> wizard_box($self -> {"template"} -> replace_langvar("STAGE_COURSE_TITLE"),
                                                       $self -> {"stages"} -> [STAGE_COURSE] -> {"icon"},
                                                       $self -> {"stages"},
                                                       STAGE_COURSE,
                                                       $self -> {"template"} -> replace_langvar("STAGE_COURSE_LONGDESC"),
                                                       $additional);
    return ($title, $message);
}


# ============================================================================
#  Wizard control functions

sub _wizard_display {
    my $self  = shift;
    my $stage = shift || 0;

    # Ensure the stage is numeric and within range.
    $stage = 0
        unless($stage =~ /^\d+$/ && $stage >= 0 && $stage <= scalar(@{$self -> {"stages"}}));

    my $stagefunc = $self -> {"stages"} -> [$stage] -> {"func"};
    return $self -> $stagefunc();
}

# ============================================================================
#  Interface functions

## @method $ page_display()
# Produce the string containing this block's full page content. This generates
# the compose page, including any errors or user feedback.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;
    my ($title, $content, $extrahead);

    my $error = $self -> check_login();
    return $error if($error);

    # Exit with a permission error unless the user has permission to compose
    if(!$self -> check_permission("process")) {
        $self -> log("error:processor:permission", "User does not have permission to use the processor wizard");

        my $userbar = $self -> {"module"} -> load_module("WebUI::Userbar");
        my $message = $self -> {"template"} -> message_box("{L_PERMISSION_FAILED_TITLE}",
                                                           "error",
                                                           "{L_PERMISSION_FAILED_SUMMARY}",
                                                           "{L_PERMISSION_PROCESSOR_DESC}",
                                                           undef,
                                                           "errorcore",
                                                           [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                              "colour"  => "blue",
                                                              "action"  => "location.href='".$self -> build_url(block => "processor", pathinfo => [])."'"} ]);

        return $self -> {"template"} -> load_template("error/general.tem",
                                                      {"***title***"     => "{L_PERMISSION_FAILED_TITLE}",
                                                       "***message***"   => $message,
                                                       "***extrahead***" => "",
                                                       "***userbar***"   => $userbar -> block_display("{L_PERMISSION_FAILED_TITLE}"),
                                                      })
    }

    # Is this an API call, or a normal page operation?
    my $apiop = $self -> is_api_operation();
    if(defined($apiop)) {
        # API call - dispatch to appropriate handler.
        given($apiop) {
            default {
                return $self -> api_html_response($self -> api_errorhash('bad_op',
                                                                         $self -> {"template"} -> replace_langvar("API_BAD_OP")))
            }
        }
    } else {
        my @pathinfo = $self -> {"cgi"} -> param('pathinfo');
        # Normal page operation.
        # ... handle operations here...

        if(!scalar(@pathinfo)) {
            ($title, $content, $extrahead) = $self -> _wizard_display();
        } else {
            given($pathinfo[0]) {
                when('stage') { ($title, $content, $extrahead) = $self -> _wizard_display($pathinfo[1]); }
                default {
                     ($title, $content, $extrahead) = $self -> _wizard_display();
                }
            }
        }

        $extrahead .= $self -> {"template"} -> load_template("stages/extrahead.tem");
        return $self -> generate_webui_page($title, $content, $extrahead, "compose");
    }
}

1;