package IEEERefHandler;

#

# $Id$

require 5.005;
use Utils qw(load_complex_template check_directory fix_entities text_to_html resolve_path load_file log_print blargh hashmerge lead_zero);
use strict;

my ($VERSION, $errstr, $htype, $desc, %typemap);

BEGIN {
    $VERSION       = 1.0;
    $htype         = 'ref';                                       # Special type for references handlers
    $desc          = 'Outputhandler IEEE reference slave plugin'; # Human-readable name
    $errstr        = '';                                          # global error string
    %typemap       = ( "book"         => "entry-book.tem",        # map of types to template names
                       "book article" => "entry-bookarticle.tem",
                       "periodical"   => "entry-periodical.tem",
                      );
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
#  Preprocessor code 
#   

# Records the location of a reference defintion or a reference to one. This
# should be provided with two hashrefs - the first is the location into which
# the reference information should be stored, the second is to a hash of
# key = value pairs containing information about the reference. The keypairs
# that should be present in the attrs hashref are:
#
# id            - coursewide ID for the reference (effectively, citation number) [all]
# type          - reference source. Valid values are 'periodical', 'book', 'book article'
# author        - primary author, 'Lastname, I. I., Jr.' or 'Lastname, Name Name, Jr.' format [all definitions]
# coauthors     - additional authors, 'Lastname, I. I., Jr., Lastname, I. I., III.' format [all defintions, optional]
# articletitle  - Article title [article/periodical]
# booktitle     - Book name [article/book]
# journalname   - Journal name [periodical]
# editor        - primary editor, 'Lastname, I. I.' format [all definitions, optional]
# coeditors     - additional editors, 'Lastname, I. I.' format [all definitions, optional]
# edition       - Book edition number [book]
# translator    - primary translator, 'Lastname, I. I.' format [book]
# cotranslators - additional translators, 'Lastname, I. I.' format [all definitions, optional]
# volume        - Publication volume [periodical, ommit for periodicals published over 12 times per year]
# issue         - Publication issue [issue (2-4 per year), 'issue, Month' (6-12 per year, 'day month' > 12 per year]
# pages         - location (N, N-N, N-N,N-N, etc), not including 'pp' [aricle/periodical] 
# date          - date of reference, month/day optional (YYYY, Month DD) [all definitions]
# location      - Publisher location [book/article]
# publisher      - Well, publisher... [book]
#
# See the documentation for more details, especially requirements on field 
# contents (especially things like naming conventions)
sub set_reference_point {
    my ($self, $storageref, $attrs, $steptitle) = @_;

    my ($theme,$module,$step) = ($attrs -> {"theme"}, $attrs -> {"module"}, $attrs -> {"step"});

    log_print($Utils::NOTICE, $self -> {"verbose"}, "Setting reference entry in $theme/$module/$step");

    # make the key the ID for ease
    my $key = $attrs -> {"id"};
    die "FATAL: malformed reference in $theme/$module/$step: no id provided\n" if(!$key);

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;
    
    # only need to do the redef check if definition is specified
    if($attrs -> {"type"}) {
        if(valid_type($attrs)) {
            # has the reference been defined before?
            my $args = $hashref -> {$key} -> {"definition"};
            blargh("Redefinition of reference $key in $theme/$module/$step - $steptitle, last set in ".$args -> {"theme"}."/".$args -> {"module"}."/".$args -> {"step"}." - ".$args -> {"title"}) if($args);       

            # record the definition location
            $attrs -> {"theme"} = $theme;
            $attrs -> {"module"} = $module;
            $attrs -> {"step"} = $step;
            $attrs -> {"steptitle"} = $steptitle;

            # store the attributes, nuking any previous settings if any
            $hashref -> {$key} -> {"definition"} = $attrs;

            # And store a backreference
            push(@{$hashref -> {$key} -> {"refs"}}, [$theme, $module, $step, $steptitle]);
        } else {
            blargh("Unsupported reference type ".$attrs -> {"type"}." in $theme/$module/$step");
        }

    # If it's not a (re)definition, mark the position anyway as we will want backrefs from the references page
    } else {
        push(@{$hashref -> {$key} -> {"refs"}}, [$theme, $module, $step, $steptitle]);
    }
}


# ============================================================================
#  Tag replacement code 
#   

# Generate the string that should replace a reference definition or link in the
# course text.
sub convert_references {
    my $self = shift;
    my $args = shift;

    my $id = $args -> {"id"};

    return "[<a href=\"../../references.html\#$id\">$id</a>]";
}


# Reduces one or more [][][] reference blocks to one [,,] block.
sub compress_references {
    my $self = shift;
    my $body = shift;

    # nuke any whitespace between reference blocks.
    $body =~  s{</a>\]\s+\[<a href=}{</a>][<a href=}gm;

    # merge successive reference blocks - ie: [1][2][3] becomes [1,2,3]
    $body =~ s{(<a href="\.\./\.\./references\.html\#.*?">.*?</a>)\]\[}{$1,}gm;

    return $body;
}


# ============================================================================
#  
#

# Converts a name from the format dictated by the references tag (surname, initials, suffix)
# into the format required by IEEE (initials surname)
sub inner_convert_name {
    my ($surname, $initials, $suffix) = @_;

    # first make sure that the initials really are initials - if they are
    # forenames then convert to initials
    if($initials !~ /^\w\.(\s+\w\.)*$/) {
        my @ilist = $initials =~ /\b(\w)\w+/g;
        $initials = join(". ", @ilist).".";
    } 

    # Strip spaces from the initials to produce L.B. format
    $initials =~ s/\s//g;

    # Concatenate into IEEE name format
    my $result = "$initials $surname";
    $result .= ", $suffix" if($suffix);

    return $result;
}


# Converts one or more names into IEEE compliant format. If only one name needs to be
# converted then only the first argument needs to be sepecified, otherwise the second
# argument is a comma seperated list of surnames, initials/names and an optional suffix
sub convert_names {
    my $name  = shift;
    my $names = shift;

    # Build the string containing all the names to proces, this may just be
    # a single name, or it may be a single name and then a list of names.
    if($names) {
        $names = "$name, $names";
    } else {
        $names = $name;
    }

    # kill all whitespace to make comma-splitting work properly
    $names =~ s/\s//g;

    # split on commas
    my @parts = split /,/, $names;

    my @results;
    for(my $i = 0; $i < scalar(@parts); $i += 2) {
        my ($surname, $initials, $suffix) = ($parts[$i], $parts[$i + 1], undef);

        # try to determine whether the third element is a suffix. This is done
        # by assuming that the suffix will end in . while surnames will not.
        if($parts[$i + 2] && $parts[$i + 2] =~ /\.$/) {
            $suffix = $parts[$i + 2];
            ++$i;
        }

        push(@results, inner_convert_name($surname, $initials, $suffix));
    }
    
    # Now put all the names together into one string, including commas and 'and'
    # as appropriate, depending on the number of names to be added.
    my $result = "";
    for(my $i = 0; $i < scalar(@results); ++$i) {
        if($i > 0) {
            if($i < scalar(@results) - 1) {
                $result .= ", ";
            } else {
                $result .= " and ";
            }
        }
        $result .= $results[$i];
    }

    return $result;
}


# Generate a string containing one reference in a form suitable for including in 
# the references page.
sub generate_refpage_entry {
    my ($self, $refdata, $backlinks) = @_;

    my $linkblock = "";
    
    # If there are any backlinks (and there should always be at least one - the
    # location of the definition) then build up a block of links to the
    # places the references are, well, referenced.
    if($backlinks && scalar(@$backlinks)) {
        my $links = "";
        for(my $i = 0; $i < scalar(@$backlinks); ++$i) {
            my $backlink = $backlinks -> [$i];

            $links .= load_complex_template($self -> {"templatebase"}."/references/IEEE/backlink-divider.tem") if($i > 0);
            $links .= load_complex_template($self -> {"templatebase"}."/references/IEEE/backlink-entry.tem", 
                                            { "***link***"  => '../'.$backlink->[0].'/'.$backlink->[1].'/step'.load_zero($backlink->[2]).'.html',
                                              "***title***" => $backlink -> [3],
                                              "***text***"  => ($i + 1) });
        }
        $linkblock = load_complex_template($self -> {"templatebase"}."/references/IEEE/backlink-block.tem", 
                                           { "***links***" => $links});
    }

    my ($authors, $editors, $translators, $edtrans) = ("", "", "", "");

    $authors = convert_names($refdata -> {"author"}, $refdata -> {"authors"}).", " if($refdata -> {"author"});

    # Build the editor string, should there be any, appending the appropriate extension
    $editors = convert_names($refdata -> {"editor"}, $refdata -> {"coeditors"}) if($refdata -> {"editor"});
    if($editors) {
        if($refdata -> {"coeditors"}) {
            $editors .= ", Eds.";
        } else {
            $editors .= ", Ed.";
        }
    }

    $translators = convert_names($refdata -> {"translator"}, $refdata -> {"cotranslators"})." Trans." if($refdata -> {"translator"});
        
    $edtrans = $editors if($editors);
    $edtrans .= ", " if($editors && $translators);
    $edtrans .= $translators;
    
    # build the title string, which may include an edition
    my $booktitle = $refdata -> {"booktitle"} || "";
    $booktitle .= ", ".$refdata -> {"edition"} if($refdata -> {"edition"});

    # spit out the reference entry.
    return load_complex_template($self -> {"templatebase"}."/references/IEEE/".$typemap{$refdata -> {"type"}},
                                 { "***id***"           => $refdata -> {"id"},
                                   "***authors***"      => $authors,
                                   "***booktitle***"    => $booktitle,
                                   "***articletitle***" => $ref -> {"articletitle"} || "",
                                   "***journalname***"  => $ref -> {"journalname"}  || "",
                                   "***volume***"       => $ref -> {"volume"}.", "  || "",
                                   "***issue***"        => $ref -> {"issue"}.", "   || "",
                                   "***pages***"        => $ref -> {"pages"}  || "",
                                   "***edtrans***"      => $edtrans,
                                   "***location***"     => $refdata -> {"location"}  || "n.p.",
                                   "***publisher***"    => $refdata -> {"publisher"} || "n.p.",
                                   "***date***"         => $refdata -> {"date"} }    || "n.d.");
}


sub write_reference_page {
    my ($self, $refdata) = @_;


}

# ============================================================================
#  Support code 
#

# returns true if the specified hash contains a supported type, false if it is
# null or not supported
sub valid_type {
    my $hash = shift;

    return $hash -> {"type"} && ($hash -> {"type"} eq "periodical" ||
                                 $hash -> {"type"} eq "book" ||
                                 $hash -> {"type"} eq "book article");
}

1;
