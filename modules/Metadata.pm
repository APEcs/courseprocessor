package Metadata;

use XML::Simple;
use Data::Dumper;
use Utils qw(string_in_array);
use strict;

my $VERSION;

BEGIN {
	$VERSION              = 1.0;
    $Data::Dumper::Purity = 1;
}


# ============================================================================
#  Constructor and identifier functions.
#

sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self = {
         @_,
    };

    die "Missing logger reference in Metadata::new()" if(!$self -> {"logger"});

    return bless $self, $class;
}

## @method void set_plugins($plugins)
# Set the plugins to the specified hashref, discarding any previous value. This
# is needed so that metadata objects can be created before plugin creation, and
# be passed a reference to the plugin hash after plugin creation.
#
# @param plugins A reference to the hash of plugins.
sub set_plugins {
    my $self = shift;

    $self -> {"plugins"} = shift;
}


# ============================================================================
#  Metadata handling
#

## @method $ validate_metadata_course($coursedir, $xml)
#  Determine whether the provided metadata contains the required elements for a
#  course metadata file, and that those elements are well-formed.
#
#  @param coursedir The directory containing the course and metadata.
#  @param xml       A reference to a hash containing the metadata.
#  @return 0 if the metadata is not valid, 1 if it is. Note that serious
#         errors in the metadata will cause the processor to exit!
sub validate_metadata_course {
    my $self      = shift;
    my $coursedir = shift;
    my $xml       = shift;

    # Note that all errors in course metadata are fatal, and can not be recovered from. Sections that
    # must be provided can't be worked around, and I don't trust plugins to halt properly.

    # Absolute minimum requirements: the course version, splash, and type must be specified.
    die "FATAL: course metadata.xml is missing course version."     if(!$xml -> {"course"} -> {"version"});
    die "FATAL: course metadata.xml is missing course splash."      if(!$xml -> {"course"} -> {"splash"});
    die "FATAL: course metadata.xml is missing course splash type." if(!$xml -> {"course"} -> {"type"});
    die "FATAL: course metadata.xml is missing course title."       if(!$xml -> {"course"} -> {"title"});

    # The type must be valid.
    die "FATAL: illegal splash type specified in course metadata."  if(!($xml -> {"course"} -> {"type"} eq "image" ||
                                                                         $xml -> {"course"} -> {"type"} eq "anim"));
    # And a message must be provided.
    die "FATAL: No front page message specified in course metadata" if(!$xml -> {"course"} -> {"message"});

    # And width and height provided.
    die "FATAL: No splash image width specified in course metadata" if(!$xml -> {"course"} -> {"width"});
    die "FATAL: No splash image height specified in course metadata" if(!$xml -> {"course"} -> {"height"});

    return 1;
}


## @method $ validate_metadata_theme($themedir, $xml)
# Attempts to determine whether the data specified in the metadata is valid
# against the current theme directory. This will check that the provided
# metadata includes the required elements and attributes, and that the
# values included appear to correspond to the data in the theme directory,
# including asking the input plugins to confirm whether the contents are
# usable by the input handler.
#
# @param themedir  The directory containing the theme and metadata.
# @param data      A reference to a hash containing the metadata.
# @return 0 if the metadata is not valid, 1 if it is. Note that serious
#         errors in the metadata will cause the processor to exit!
sub validate_metadata_theme {
    my $self     = shift;
    my $themedir = shift;
    my $xml      = shift;

    my ($shortname) = $themedir =~ m|^.*/(.*?)$|;

    # check the theme name and title have been specified.
    die "FATAL: metadata for theme $shortname missing theme title." if(!$xml -> {"theme"} -> {"title"});
    die "FATAL: metadata for theme $shortname missing theme name."  if(!$xml -> {"theme"} -> {"name"});
    die "FATAL: metadata for theme $shortname missing theme index order."  if(!$xml -> {"theme"} -> {"indexorder"});

    # Check modules
    foreach my $module (keys(%{$xml -> {"theme"} -> {"module"}})) {
        next if($module eq "dummy"); # don't bother validating the dummy module

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "checking $module");
        die "FATAL: metadata for theme $shortname missing module title for '$module'." if(!$xml -> {"theme"} -> {"module"} -> {$module} -> {"title"});
        die "FATAL: metadata for theme $shortname missing module level for '$module'." if(!$xml -> {"theme"} -> {"module"} -> {$module} -> {"level"});
        die "FATAL: metadata for theme $shortname missing module index order for '$module'." if(!$xml -> {"theme"} -> {"module"} -> {$module} -> {"indexorder"});

        # check that any prereqs are valid.
        if($xml -> {"theme"} -> {"module"} -> {$module} -> {"prerequisites"}) {
            # If we have prerequisites, we need a reference to a hash (essentially just the target element)
            # If we have anything else - say an arrayref - then the xml is b0rken and can not be easily handled
            # (we could work around it, but the user should be giving us valid xml, damnit)
            die "FATAL: Error in metadata: please check that each module has at most one <prerequisites> element.\n" if(ref($xml -> {"theme"} -> {"module"} -> {$module} -> {"prerequisites"}) ne "HASH");

            # The target should be a reference to an array of names, even when there's only one
            my $targets = $xml -> {"theme"} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
            die "FATAL: Error in metadata: malformed prerequisite list for module $module.\n" if(!ref($targets) || ref($targets) ne "ARRAY");

            # Check the target exists...
            foreach my $target (@$targets) {
                die "FATAL: metadata for theme $shortname contains unknown prerequisite '$target' for '$module'.\n"
                    if(!$xml -> {"theme"} -> {"module"} -> {$target});

                # Does the target list this module as a leadsto?
                if(!$xml -> {"theme"} -> {"module"} -> {$target} -> {"leadsto"} ||
                   !$xml -> {"theme"} -> {"module"} -> {$target} -> {"leadsto"} -> {"target"} ||
                   !defined(string_in_array($xml -> {"theme"} -> {"module"} -> {$target} -> {"leadsto"} -> {"target"}, $module))) {

                    # this module is not the target's leadsto, so make it so.
                    push(@{$xml -> {"theme"} -> {"module"} -> {$target} -> {"leadsto"} -> {"target"}}, $module);
                }
            }
        }

        # check that any leadstos are valid.
        if($xml -> {"theme"} -> {"module"} -> {$module} -> {"leadsto"}) {
            # As above, if we have leadstos, we need a reference to a hash (essentially just the target element)
            die "FATAL: Error in metadata: please check that each module has at most one <leadsto> element.\n" if(ref($xml -> {"theme"} -> {"module"} -> {$module} -> {"leadsto"}) ne "HASH");

            # The target should be a reference to an array of names, even when there's only one
            my $targets = $xml -> {"theme"} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
            die "FATAL: Error in metadata: malformed leadsto list for module $module.\n" if(!ref($targets) || ref($targets) ne "ARRAY");

            # Check the target exists
            foreach my $target (@$targets) {
                die "FATAL: metadata for theme $shortname contains unknown prerequisite '$target' for '$module'.\n"
                    if(!$xml -> {"theme"} -> {"module"} -> {$target});

                # Does the target list this module as a prerequisite?
                if(!$xml -> {"theme"} -> {"module"} -> {$target} -> {"prerequisites"} ||
                   !$xml -> {"theme"} -> {"module"} -> {$target} -> {"prerequisites"} -> {"target"} ||
                   !defined(string_in_array($xml -> {"theme"} -> {"module"} -> {$target} -> {"prerequisites"} -> {"target"}, $module))) {

                    # this module is not the target's prerequisite, so make it so.
                    push(@{$xml -> {"theme"} -> {"module"} -> {$target} -> {"prerequisites"} -> {"target"}}, $module);
                }
            }
        }

        # Do we have any objectives?
        if($xml -> {"theme"} -> {"module"} -> {$module} -> {"objectives"}) {
            die "FATAL: Error in metadata: $module contains an objectives element with no valid objective elements\n" if(ref($xml -> {"theme"} -> {"module"} -> {$module} -> {"objectives"}) ne "HASH" ||
                                                                                                                         !$xml -> {"theme"} -> {"module"} -> {$module} -> {"objectives"} -> {"objective"} ||
                                                                                                                         !scalar(@{$xml -> {"theme"} -> {"module"} -> {$module} -> {"objectives"} -> {"objective"}}));
        }

        # Or any outcomes?
        if($xml -> {"theme"} -> {"module"} -> {$module} -> {"outcomes"}) {
            die "FATAL: Error in metadata: $module contains an outcomes element with no valid outcome elements\n" if(ref($xml -> {"theme"} -> {"module"} -> {$module} -> {"outcomes"}) ne "HASH" ||
                                                                                                                     !$xml -> {"theme"} -> {"module"} -> {$module} -> {"outcomes"} -> {"outcome"} ||
                                                                                                                     !scalar(@{$xml -> {"theme"} -> {"module"} -> {$module} -> {"outcomes"} -> {"outcome"}}));
        }

        # Do the input handler(s) think the module is valid?
        my $valid = 0;
        my @errors = ();

        if($self -> {"plugins"} -> {"input"}) {
            foreach my $plugin (sort(keys(%{$self -> {"plugins"} -> {"input"}}))) {
                if($self -> {"plugins"} -> {"input"} -> {$plugin} -> {"use"}) {
                    my $result = $self -> {"plugins"} -> {"input"} -> {$plugin} -> {"obj"} -> module_check($themedir, $module);
                    if(!$result) {
                        $valid = 1;
                        last;
                    } else {
                        push(@errors, $result);
                    }
                }
            }
        } else {
            # No input handlers to do any testing, just assume it's valid then...
            $valid = 1;
        }

        if(!$valid) {
            $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "$module in metadata for theme $shortname can not be validated. Output from input plugin checks is: ".join("\n", @errors));
            return 0;
        } else {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "$module in metadta for theme $shortname appears to be valid.");
        }
    }

    # If we have a maps section, we must have at least one map section
    if($xml -> {"theme"} -> {"maps"}) {
        die "FATAL: Error in metadata: metadata for theme $shortname contains an includes element with no valid resources\n" if(ref($xml -> {"theme"} -> {"maps"}) ne "HASH" ||
                                                                                                                          !$xml -> {"theme"} -> {"maps"} -> {"map"} ||
                                                                                                                          !scalar(@{$xml -> {"theme"} -> {"maps"} -> {"map"}}));
    }

    # Do we have any theme-level objectives?
    if($xml -> {"theme"} -> {"objectives"}) {
        die "FATAL: Error in metadata: metadata for theme $shortname contains an objectives element with no valid objective elements\n" if(ref($xml -> {"theme"} -> {"objectives"}) ne "HASH" ||
                                                                                                                                     !$xml -> {"theme"} -> {"objectives"} -> {"objective"} ||
                                                                                                                                     !scalar(@{$xml -> {"theme"} -> {"objectives"} -> {"objective"}}));
    }

    # Or any theme-level outcomes?
    if($xml -> {"theme"} -> {"outcomes"}) {
        die "FATAL: Error in metadata: metadata for theme $shortname contains an outcomes element with no valid outcome elements\n" if(ref($xml -> {"theme"} -> {"outcomes"}) ne "HASH" ||
                                                                                                                                 !$xml -> {"theme"} -> {"outcomes"} -> {"outcome"} ||
                                                                                                                                 !scalar(@{$xml -> {"theme"} -> {"outcomes"} -> {"outcome"}}));
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "metadata for theme $shortname is valid");

    return 1;
}


## @method $ validate_metadata($srcdir, $xml)
#  Attempt to validate the contents of the specified xml, based on the type of element
#  at the root of the xml ('course' or 'theme' for example).
#
# @param srcdir The directory containing the metadata.
# @param xml    A reference to a hash containing the metadata.
# @return 0 if the metadata is not valid, 1 if it is. Note that serious
#         errors in the metadata will cause the processor to exit!
sub validate_metadata {
    my $self   = shift;
    my $srcdir = shift;
    my $xml    = shift;

    # Obtain the metadata type from the first key in the hash (should be the xml root node)
    my $type = (keys(%$xml))[0];

    if($type eq "course") {
        return $self -> validate_metadata_course($srcdir, $xml);
    } elsif($type eq "theme") {
        return $self -> validate_metadata_theme($srcdir, $xml);

    # Fallback case, assume invalid metadata as it doesn't have a recognised root type
    } else {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unknown metadata root '$type' in metadata.xml loaded form $srcdir");
    }

    return 0;
}


## @method $ load_metadata($srcdir, $validate, $plugins)
# Load an XML metadata file, optionally does basic checks on the loaded data to
# ensure that the minimal requirements for the metadata consistency and content
# are met.
#
# @param srcdir    The directory to load metdata from.
# @param name      The human-readable name of the directory the metadata is being read from.
# @param validate  If true, the metadata is validated to ensure it contains
#                  required sections
# @return 1 if the metadata file does not exist, 0 if the metadata exists but
#         it is not valid, otherwise this returns a reference to a hash
#         containing the metadata information.
sub load_metadata {
    my $self     = shift;
    my $srcdir   = shift;
    my $name     = shift;
    my $validate = shift;

    my $data;

    # If the xml file exists, attempt to load it
    if(-e "$srcdir/metadata.xml") {
        eval { $data = XMLin("$srcdir/metadata.xml",
                             KeepRoot => 1,
                             ForceArray => [ 'target', 'include', 'exclude', 'resource', 'file', 'module', 'map', 'outcome', 'objective', 'step' ],
                             KeyAttr => {step => 'title', module => 'name', theme => 'name'}); };

        die "FATAL: Unable to parse $name metadata.xml file. Errors were:\n$@\n" if($@);

        # If we need to validate the metadata, go ahead and do so.
        if($validate) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Metadata contents: \n".Data::Dumper -> Dump([$data], ['*data']));
            return 0 if(!$self -> validate_metadata($srcdir, $data));
        }
    } else {
        return 1;
    }

    # Get here and the metadata exists and is valid, so return it
    return $data;
}


## @method $ load_metadata($content, $validate, $plugins)
# PArse the XML in the specified string, optionally does basic checks on the data
# to ensure that the minimal requirements for the metadata consistency and content
# are met.
#
# @param content   The XML string to parse.
# @param name      The human-readable name of the metadata being processed.
# @param validate  If true, the metadata is validated to ensure it contains
#                  required sections
# @return 0 if the metadata is not valid, otherwise this returns a reference to a hash
#         containing the metadata information.
sub parse_metadata {
    my $self     = shift;
    my $content  = shift;
    my $name     = shift;
    my $validate = shift;

    my $data;

    eval { $data = XMLin($content,
                         KeepRoot => 1,
                         ForceArray => [ 'target', 'include', 'exclude', 'resource', 'file', 'module', 'map', 'outcome', 'objective', 'step' ],
                         KeyAttr => {step => 'title', module => 'name', theme => 'name'}); };

    die "FATAL: Unable to parse $name metadata. Errors were:\n$@\n" if($@);

    # If we need to validate the metadata, go ahead and do so.
    if($validate) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Metadata contents: \n".Data::Dumper -> Dump([$data], ['*data']));
        return 0 if(!$self -> validate_metadata($srcdir, $data));
    }

    # Get here and the metadata exists and is valid, so return it
    return $data;
}



1;
