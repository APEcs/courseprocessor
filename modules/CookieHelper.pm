# @file CookieHelper.pm
# Functions to help encode and decode cookie data to support database
# storage of cookies.
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0

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

package Utils;
use Exporter;
use HTTP::Cookies;
use HTTP::Date qw(str2time);
use HTTP::Headers::Util qw(_split_header_words);
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(set_cookies get_cookies);
our $VERSION   = 2.1;

## @fn void set_cookies($jar, $dbh, $table, $sessid)
# Extract the cookies from the specified cookie jar, and store them in
# the specified table. 
#
# @param jar    A HTTP::Cookies object containing the cookies to store.
# @param dbh    A reference to a database handle to send queries through.
# @param table  The name of the session data table to store cookies in.
# @param sessid The id of the session to associate the cookies with.
sub set_cookies {
    my ($jar, $dbh, $table, $sessid) = @_;

    # Build the queries needed
    my $remcookie = $dbh -> prepare("DELETE FROM $table WHERE id = ? AND key = ?");
    my $addcookie = $dbh -> prepare("INSERT INTO $table VALUES(?, ?, ?)");

    # Get the string version of the jar. We could use HTTP::Cookies -> scan() instead, but
    # we're going to end up storing the cookie as a string, may as well just do this...
    my $cookies = $jar -> as_string();

    # Split up...
    my @lines = split(/^/, $cookies);
    foreach my $line (@lines) {
        chomp($line);

        # Work out the key name to use
        my ($key) = $line =~ /^Set-Cookie3: (.*?)=/;

        # Remove the key if it already exists
        $remcookie -> execute($sessid, $key)
            or die "FATAL: Unable to remove old entry for $key, session $sessid. Error was: ".$dbh -> errstr;

        # And add the new value
        $addcookie -> execute($sessid, $key, $line)
            or die "FATAL: Unable to add entry for $key, session $sessid. Error was: ".$dbh -> errstr;
    }
}


## @fn $ get_cookies($dbh, $table, $sessid)
# Create a cookie jar containing all the cookies stored for the specified 
# session. This will go through all the data stored for the specified session
# and if it encounters a cookie value it stores it in a cookie jar.
#
# @param dbh    A reference to a database handle to send queries through.
# @param table  The name of the session data table.
# @param sessid The id of the session to obtain cookies from.
# @return A cookie jar containing the session's stored cookies. 
sub set_cookies {
    my ($dbh, $table, $sessid) = @_;

    # First, the fetch query...
    my $getcookie = $dbh -> prepare("SELECT value FROM $table WHERE id = ? AND value LIKE 'Set-Cookie3: %'");

    # A new empty cookie jar to store cookies in...
    my $jar = HTTP::Cookie -> new();

    # Off we go...
    $getcookie -> execute($sessid)
        or die "FATAL: Unable to obtain stored cookies for session $sessid. Error was: ".$dbh -> errstr;

    # Process each cookie directly into the jar. Yes, this is Naughty, but
    # HTTP::Cookie provides no actually useful way to shove one of its own
    # generated strings back into a jar, ffs (protip guys: if you have a function
    # that converts your object to a string, provide a function that converts that
    # string to an object. Say, a parameter to new())
    while(my $cookieval = $getcookie -> fetchrow_arrayref()) {
        # Remove the Set-Cookie3:...
        $cookieval =~ s/^Set-Cookie3:\s*//;

        # Much of what follows is lifted from the HTTP::Cookie code...
        my $cookie;
        for $cookie (_split_header_words($cookieval)) {
            my($key,$val) = splice(@$cookie, 0, 2);

            my %hash;
            while (@$cookie) {
                my $k = shift @$cookie;
                my $v = shift @$cookie;
                $hash{$k} = $v;
            }
            
            my $version   = delete $hash{version};
            my $path      = delete $hash{path};
            my $domain    = delete $hash{domain};
            my $port      = delete $hash{port};
            my $expires   = str2time(delete $hash{expires});
            my $path_spec = exists $hash{path_spec}; delete $hash{path_spec};
            my $secure    = exists $hash{secure};    delete $hash{secure};
            my $discard   = exists $hash{discard};   delete $hash{discard};

            my @array =	($version,$val,$port,$path_spec,$secure,$expires,$discard);
            push(@array, \%hash) if %hash;
            $jar -> {"COOKIES"}{$domain}{$path}{$key} = \@array;
        }
    }

    # Return the jar, which may or may not have any actual cookie in it.
    return $jar;
}

1;
