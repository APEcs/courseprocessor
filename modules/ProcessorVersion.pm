package ProcessorVersion;

use Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(get_version);

my $wiki2course = "1.7 (20 Jun 2017)";
my $course2wiki = "1.6 (20 Apr 2017)";
my $processor   = "3.8.9 (20 Apr 2017)";
my $release     = "3.8.9 (Sudbury Hill)";

sub get_version {
    my $mode = shift;

    if(lc($mode) eq "processor") {
        return "Processor $processor [Toolchain version $release]";
    } elsif(lc($mode) eq "wiki2course") {
        return "Wiki export tool $wiki2course [Toolchain version $release]";
    } elsif(lc($mode) eq "course2wiki") {
        return "Course import tool $course2wiki [Toolchain version $release]";
    } else {
        return "Unknown mode";
    }
}

1;
