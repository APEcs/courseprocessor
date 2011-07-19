package ProcessorVersion;

use Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(get_version);

my $wiki2course = "1.2 (19 July 2011)";
my $course2wiki = "1.1 (11 July 2011)";
my $processor   = "3.8.3 (19 July 2011)";
my $release     = "3.8.3c";

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
