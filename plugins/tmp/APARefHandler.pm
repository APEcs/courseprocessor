package HTMLOutputHandlerTNG;

#

# $Id$

require 5.005;
use Utils qw(load_complex_template check_directory fix_entities text_to_html resolve_path load_file log_print blargh);
use strict;

my ($VERSION, $type, $errstr, $htype, $desc,);

BEGIN {
	$VERSION       = 1.0;
    $htype         = 'reference';                                # Special type for references handlers
    $desc          = 'Outputhandler APA reference slave plugin'; # Human-readable name
	$errstr        = '';                                         # global error string
}

# ============================================================================
#  Constructor and identifier functions.  
#   
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self     = {
        "verbose" => 0, # set to 1 to enable additional output
        @_
    };

    return bless $self, $class;
}

# Top level handler type ID
sub get_type { return $htype };

# Handler descriptive text
sub get_description { return $desc };

# Handler version number
sub get_version { return $VERSION };


# ============================================================================
#  
#   

# Record the location of referencedefinitions or references


# Records the location of a reference defintion or a reference to one. This
# should be provided with two hashrefs - the first is the location into which
# the reference information should be stored, the second is to a hash of
# key = value pairs containing information about the reference. The keypairs
# that should be present in the attrs hashref are:
#
# id        - coursewide unique id for the reference (NOT VISIBLE IN THE PROCESSED COURSE) [all refs]
# type      - reference source. Valid values are 'ref', 'periodical', 'book', 'newspaper', 'webpage', 'forum', 'personal'
# author    - primary author, 'Lastname, I. I.' format [all definitions, see note below]
# coauthors - additional authors, 'Lastname, I. I., Lastname, I. I.' format [all defintions, optional]
# date      - date of reference, month/day optional (YYYY, Month DD) [all definitions]
# location  - page/paragraph of the resource [
sub set_reference_point {
    my ($self, $storageref, $attrs) = @_;

    my ($theme,$module,$step) = ($attrs -> {"theme"}, $attrs -> {"module"}, $attrs -> {"step"});


    log_print($Utils::NOTICE, $self -> {"verbose"}, "Setting reference entry in $theme/$module/$step");

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;
     
    # convert the term to a lowercase, space-converted name 
    my $key = lc($attrs -> {"id"});
    $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # only need to do the redef check if definition is specified
    if($attrs -> {"type"} eq "ref") {
        my $args = $storageref -> {$key} -> {"defsource"};
#        blargh("Redefinition of term $term in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]") if($args);       

#        $storageref -> {$key} -> {"term"}       = $term;
#        $storageref -> {$key} -> {"definition"} = $definition;
#        $storageref -> {$key} -> {"defsource"}  = [$theme, $module, $step];
#        push(@{$storageref -> {$key} -> {"refs"}}, [$theme, $module, $step]);
    
    # If it's not a (re)definition, mark the position anyway as we will want backrefs from the glossary
    } else {
        push(@{$storageref -> {$key} -> {"refs"}}, [$theme, $module, $step]);
    }
}

1;
