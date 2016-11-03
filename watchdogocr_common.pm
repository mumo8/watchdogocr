# Config file for watchdog ocr utilite
# korolev-ia [at] yandex.ru
# version 1.2 2016.11.02
#
#
use Data::Dumper;
use Getopt::Long;
use DBI;
use lib "/home/directware/perl5/lib/perl5/x86_64-linux-gnu-thread-multi/"; 
use DBD::ODBC;
use XML::Simple;
use JSON::XS;
use File::Basename;
use Cwd;

# if $DEBUG=1 then print all messages to stderr.
# if $DEBUG=0 then write messages only to $LOGFILE
$DEBUG=1;

# main working dir
chdir ( dirname($0) );
$WORKING_DIR = getcwd();
#$WORKING_DIR='/home/directware/watchdogocr'; # uncomment this only if you use different file for binary and all other files


# check new files every $SCAN_INTERVAL ( in seconds ) for daemon mode
$SCAN_INTERVAL=60; 


# 
$LOGDIR="$WORKING_DIR/var/log";
$TMPDIR="$WORKING_DIR/var/tmp";
$WATCHDOGOCR_FILE="$WORKING_DIR/watchdogocr_file.pl";

# log file for errors
$LOGFILE="$LOGDIR/".basename($0).".log";

# scan new pdf files
$SCAN_DIR='/home/directware/docs/in';
$DIR_FOR_FILES_IN_PROCESS="$SCAN_DIR/process";
$DIR_FOR_PAGES_OCR="$SCAN_DIR/pages";
$DIR_FOR_RUNNING_OCR="$SCAN_DIR/running";
$DIR_FOR_FINISHED_OCR="$SCAN_DIR/finished";
$DIR_FOR_FAILED_OCR="$SCAN_DIR/failed";

$LAST_SCANED_TIME_DB="$WORKING_DIR/var/last_scaned_time_dir0.txt" ;
$CHECK_FILE_MASK='([\w|\s]+)(?<!_ocr)\.pdf';
#$CHECK_FILE_MASK_OCR='([\w|\s]+_ocr)\.pdf';
$CHECK_FILE_MASK_PAGE='([\w|\s]+)_ID(\d+)_PAGE(\d+)';
$MAX_FILES_IN_OCR_QUEUE=3;


# db settings
@DB_CONNECTION=(
	"dbi:ODBC:MSSQLTestServer", 
	"quickbooks", 
	"pcgi21"
	);
	

######################## common used functions 	########################
	
	
sub db_connect {
	my $dbh = DBI->connect( @DB_CONNECTION,  {
		PrintError       => 0,
		RaiseError       => 1,
		AutoCommit       => 1,
		FetchHashKeyName => 'NAME_lc',
		# we will set buffer for strings to 50mb
		LongReadLen => 50000000, 
	}) ; 

	unless( $dbh ) {
		w2log( "Cannot connect to database: $!") ;
		return 0;
	}
	return $dbh;
}

sub db_disconnect {
	my $dbh=shift;
	$dbh->disconnect;
}

	

sub get_date {
	my $time=shift() || time();
	my $format=shift || "%s-%.2i-%.2i %.2i:%.2i:%.2i";
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	$year+=1900;$mon++;
    return sprintf( $format,$year,$mon,$mday,$hour,$min,$sec);
}	


sub w2log {
	my $msg=shift;
	# daily log file
	my $log=shift;
	unless( $log ) {
		$log=$LOGFILE; 
	}
	open (LOG,">>$log") || print STDERR ("Can't open file $log. $msg") ;
	print LOG get_date()."\t$msg\n";
	print STDERR "$msg\n" if( $DEBUG );
	close (LOG);
}


sub ReadFile {
	my $filename=shift;
	my $ret="";
#	open (IN,"<:encoding(UTF-8)","$filename") || w2log("Can't open file $filename") ;
	open (IN,"'$filename'") || w2log("Can't open file '$filename'") ;
		binmode(IN);
		while (<IN>) { $ret.=$_; }
	close (IN);
	return $ret;
}	
					
sub WriteFile {
	my $filename=shift;
	my $body=shift;
	unless( open (OUT,">$filename")) { w2log("Can't open file $filename for write" ) ;return 0; }
	print OUT $body;
	close (OUT);
	return 1;
}	

sub AppendFile {
	my $filename=shift;
	my $body=shift;
	unless( open (OUT,">>$filename")) { w2log("Can't open file $filename for append" ) ;return 0; }
	print OUT $body;
	close (OUT);
	return 1;
}	

					
sub xml2json {
        my $xml=shift;
		my $ref;
		eval { $ref=XMLin( $xml,  ForceArray=>1 , ForceContent =>0 , KeyAttr => 1, KeepRoot => 1, SuppressEmpty => '' ) } ;
        #eval { $ref=parse_string( $xml,  ForceArray=>1 , ForceContent =>0 , KeyAttr => 1, KeepRoot => 1, SuppressEmpty => '' ) } ;
                if($@) {
                        w2log ( "XML file $filename error: $@" );
                        return( undef );
						
                }
		my $coder = JSON::XS->new->utf8->pretty->allow_nonref; # bugs with JSON module and threads. we need use JSON::XS
		my $json = $coder->encode ($ref);
        return $json;
}

sub get_files_in_dir {
	my $dir=shift;
	my $mask=shift;
	$mask='^.+$' unless( $mask );
	my @ls;
	opendir(DIR, $dir) || w2log( "can't opendir $dir: $!" );
		@ls = reverse sort grep { /^$mask$/ && -f "$dir/$_" } readdir(DIR);
	closedir DIR;
	return @ls;
}


sub get_prefix {
	my $filename=shift;
	my $prefix='';	
	if( $filename=~/^$CHECK_FILE_MASK$/ ) {
		$prefix=$1;
	}	
	return ( $prefix );
}


sub get_prefix_page {
	my $filename=shift;
	my $prefix='';	
	my $page=0;	
	my $id=0;
	if( $filename=~/^$CHECK_FILE_MASK_PAGE/ ) {
		$prefix=$1;
		$id=$2;
		$page=$3;
	}
	return ( $prefix, $page, $id );
}


sub InsertRecord {
	my $dbh=shift;
	my $stmt=shift; # sql
	my $row=shift; # data

	eval {
		my $sth = $dbh->prepare( $stmt );
		$sth->execute( @{$row} );
	};
	if( $@ ){
		w2log( "Error insert. Sql:$stmt . Error: $@" );
		return 0;
	}
return ( 1 );	
}

sub UpdateRecord {
	my $dbh=shift;
	my $id=shift;
	my $table=shift;
	my $row=shift;
	my @Val=();
	my @Col=();
	foreach $key ( keys %{ $row }) {
		push ( @Col," $key = ? " ) ;
		push ( @Val, $row->{$key} ) ;
	}
		push ( @Val, $id ) ;
	my $stmt ="UPDATE $table set " . join(',',@Col ). " where id=?  ";
	eval {
		my $sth = $dbh->prepare( $stmt );
		$sth->execute( @Val );
	};
	if( $@ ){
		w2log( "Error update. Sql:$stmt . Error: $@" );
		return 0;
	}	
	return ( 1 );	
}

sub DeleteRecord {
	my $dbh=shift;
	my $id=shift;
	my $table=shift;
	my $stmt ="DELETE FROM $table WHERE id = ? ; ";
	eval {
		my $sth = $dbh->prepare( $stmt );
		$sth->execute( $id );
	};
	if( $@ ){
		w2log( "Error delete record. Sql:$stmt . Error: $@" );
		return 0;
	}	
	return 1;
}


1;