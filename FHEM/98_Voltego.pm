package main;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;
use DateTime;
use DateTime::Format::Strptime;
use List::Util qw(max);
use Date::Parse;

my %Voltego_gets = (
    update         => " ",
    newToken       => " "
);

my %Voltego_sets = (
    start        => " ",
    stop         => " ",
    interval     => " "
);

my %url = (
    getOAuthToken => 'https://api.voltego.de/oauth/token',
    getPriceValue => 'https://api.voltego.de/market_data/day_ahead/DE_LU/60?from=#fromDate##TimeZone#&tz=#TimeZone#&unit=EUR-ct_kWh',
);

# OAuth Settings
my %oauth = (
    scope         => 'market_data:read',
    grant_type    => 'client_credentials'
);

sub Voltego_encrypt($);
sub Voltego_decrypt($);

sub Voltego_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}     = 'Voltego_Define';
    $hash->{UndefFn}   = 'Voltego_Undef';
    $hash->{SetFn}     = 'Voltego_Set';
    $hash->{GetFn}     = 'Voltego_Get';
    $hash->{AttrFn}    = 'Voltego_Attr';
    $hash->{AttrList}  = 	
      'showEPEXSpot:yes,no '
	. 'showWithTax:yes,no '
	. 'showWithLeviesTaxes:yes,no '
	. 'showCurrentHour:yes,no '
	. 'showNextHour:yes,no '
	. 'showPreviousHour:yes,no '
    . 'TaxRate '
	. 'LeviesTaxes_ct '
	. 'NetCosts_ct '
	.$readingFnAttributes;

    Log 3, "Voltego module initialized.";
}

sub Voltego_Define($$) {
    my ( $hash, $def ) = @_;
    my @param = split( "[ \t]+", $def );
    my $name  = $hash->{NAME};

    Log3 $name, 3, "Voltego_Define $name: called ";

    my $errmsg = '';

    # Check parameter(s) - Must be min 4 in total (counts strings not purly parameter, interval is optional)
    if ( int(@param) < 4 ) {
        $errmsg = return "syntax error: define <name> Voltego <client_id> <client_secret> [Interval]";
        Log3 $name, 1, "Voltego $name: " . $errmsg;
        return $errmsg;
    }

	#Take clientId 
    my $clientId = $param[2];
    $hash->{clientId} = $clientId;

	#Take clientSecret and use custom encryption.
	# Encryption is taken from fitbit / withings / tado module
	my $clientSecret = Voltego_encrypt($param[3]);

	$hash->{clientSecret} = $clientSecret;

	if (defined $param[4]) {
		$hash->{DEF} = sprintf("%s %s %s", InternalVal($name,'clientId', undef), $clientSecret, $param[4]);
	} else {
		$hash->{DEF} = sprintf("%s %s", InternalVal($name,'clientId', undef) ,$clientSecret);
	}

    #Check if interval is set and numeric.
    #If not set -> set to 600 seconds
    #If less then 60 seconds set to 6000
    #If not an integer abort with failure.
    my $interval = 600;

    if ( defined $param[4] ) {
        if ( $param[4] =~ /^\d+$/ ) {
            $interval = $param[4];
        }
        else {
            $errmsg = "Specify valid integer value for interval. Whole numbers > 5 only. Format: define <name> Voltego <clientId> <clientSecret> [interval]";
            Log3 $name, 1, "Voltego $name: " . $errmsg;
            return $errmsg;
        }
    }

    if ( $interval < 60 ) { $interval = 600; }
    $hash->{INTERVAL} = $interval;

    readingsSingleUpdate( $hash, 'state', 'Undefined', 0 );

    CommandAttr(undef, $name.' showEPEXSpot yes') if ( AttrVal($name,'showEPEXSpot','none') eq 'none' );
    CommandAttr(undef, $name.' showWithTax no') if ( AttrVal($name,'showWithTax','none') eq 'none' );
    CommandAttr(undef, $name.' showWithLeviesTaxes yes') if ( AttrVal($name,'showWithLeviesTaxes','none') eq 'none' );

    CommandAttr(undef, $name.' showCurrentHour yes') if ( AttrVal($name,'v','none') eq 'none' );
    CommandAttr(undef, $name.' showNextHour yes') if ( AttrVal($name,'showNextHour','none') eq 'none' );
    CommandAttr(undef, $name.' showPreviousHour yes') if ( AttrVal($name,'showPreviousHour','none') eq 'none' );

    CommandAttr(undef, $name.' TaxRate 19') if ( AttrVal($name,'TaxRate','none') eq 'none' );
    CommandAttr(undef, $name.' LeviesTaxes_ct 0.00') if ( AttrVal($name,'LeviesTaxes_ct','none') eq 'none' );
    CommandAttr(undef, $name.' NetCosts_ct 0.00') if ( AttrVal($name,'NetCosts_ct','none') eq 'none' );

    RemoveInternalTimer($hash);

    Log3 $name, 1,
      sprintf( "Voltego_Define %s: Starting timer with interval %s",
      $name, InternalVal( $name, 'INTERVAL', undef ) );

    InternalTimer( gettimeofday() + 15, "Voltego_UpdateDueToTimer", $hash ) if ( defined $hash );

    InternalTimer( gettimeofday() + 45, "Voltego_HourTaskTimer", $hash ) if ( defined $hash );
    
    return undef;
}

sub Voltego_Undef($$) {
    my ( $hash, $arg ) = @_;

    RemoveInternalTimer($hash);
    return undef;
}

sub Voltego_LoadToken {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME};
    $tokenLifeTime = 0 if ( !defined $tokenLifeTime || $tokenLifeTime eq '' );
    my $Token = undef;

    $Token = $hash->{'.TOKEN'};

    if ( $@ || $tokenLifeTime < gettimeofday() ) {
        Log3 $name, 5,
          "Voltego $name" . ": "
          . "Error while loading: $@ ,requesting new one"
          if $@;
        Log3 $name, 5,
          "Voltego $name" . ": " . "Token is expired, requesting new one"
          if $tokenLifeTime < gettimeofday();
        $Token = Voltego_NewTokenRequest($hash);
    }
    else {
        Log3 $name, 5,
            "Voltego $name" . ": "
          . "Token expires at "
          . localtime($tokenLifeTime);

        # if token is about to expire, refresh him
        if ( ( $tokenLifeTime - 45 ) < gettimeofday() ) {
            Log3 $name, 5,
              "Voltego $name" . ": " . "Token will expire soon, refreshing";
            $Token = Voltego_NewTokenRequest($hash);
        }
    }
    return $Token if $Token;
}

sub Voltego_NewTokenRequest {
    my $hash         = shift;
    my $name         = $hash->{NAME};
    my $clientSecret = Voltego_decrypt( InternalVal( $name, 'clientSecret', undef ) );
    my $clientId     = InternalVal( $name, 'clientId', undef );

    Log3 $name, 5, "Voltego $name" . ": " . "calling NewTokenRequest()";
    #Log3 $name, 5, "Voltego $name" . "clientSecret: " . $clientSecret;
    #Log3 $name, 5, "Voltego $name" . "clientId: " . $clientId;

    my $data = {
        client_id     => $clientId, 
        client_secret => $clientSecret,
        scope         => $oauth{scope},
        grant_type    => 'client_credentials'
    };

    my $param = {
        url     => $url{getOAuthToken},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Voltego $name" . ": "
          . "NewTokenRequest: Error while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData) };
        if ($@) {
            Log3 $name, 3, "Voltego $name" . ": "
              . "NewTokenRequest: decode_json failed, invalid json. error: $@ ";
        }
        else {
            #write token data in hash
            if ( defined($decoded_data) ) {
                $hash->{'.TOKEN'} = $decoded_data;
            }

            # token lifetime management
            if ( defined($decoded_data) ) {
                $hash->{TOKEN_LIFETIME} =
                  gettimeofday() + $decoded_data->{'expires_in'};
            }
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "Voltego $name" . ": "
              . "Retrived new authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";

            return $decoded_data;
        }
    }
    return;
}

sub Voltego_Get($@) {
    my ( $hash, $name, @args ) = @_;

    return '"get Voltego" needs at least one argument' if ( int(@args) < 1 );

    my $opt = shift @args;
    if ( !$Voltego_gets{$opt} ) {
        my @cList = keys %Voltego_gets;
        return "Unknown! argument $opt, choose one of " . join( " ", @cList );
    }

    my $cmd = $args[0];
    my $arg = $args[1];

    if ( $opt eq "update" ) {

        Log3 $name, 3, "Voltego_Get Voltego_RequestUpdate $name: Updating ....s";
        $hash->{LOCAL} = 1;
        #($hash);

        Voltego_RequestUpdate($hash);

        delete $hash->{LOCAL};
        return undef;

    }
    elsif ( $opt eq 'newToken' ) {
        Log3 $name, 3, "Voltego: get $name: processing ($opt)";
        Voltego_NewTokenRequest($hash);
        Log3 $name, 3, "Voltego $name" . ": " . "$opt finished\n";
    }
    else {

        my @cList = keys %Voltego_gets;
        return "Unknown v2 argument $opt, choose one of " . join( " ", @cList );
    }
}

sub Voltego_Set($@) {
    my ( $hash, $name, @param ) = @_;

    return '"set $name" needs at least one argument' if ( int(@param) < 1 );

    my $opt   = shift @param;
    my $value = join( "", @param );

    if ( !defined( $Voltego_sets{$opt} ) ) {
        my @cList = keys %Voltego_sets;
        return "Unknown argument $opt, choose one of start stop interval";
    }

    if ( $opt eq "start" ) {

        readingsSingleUpdate( $hash, 'state', 'Started', 0 );

        RemoveInternalTimer($hash);

        $hash->{LOCAL} = 1;
        Voltego_RequestUpdate($hash);
        delete $hash->{LOCAL};

        Voltego_HourTaskTimer($hash);

        InternalTimer( gettimeofday() + InternalVal( $name, 'INTERVAL', undef ), "Voltego_UpdateDueToTimer", $hash );

        Log3 $name, 1,
          sprintf( "Voltego_Set %s: Updated readings and started timer to automatically update readings with interval %s",
            $name, InternalVal( $name, 'INTERVAL', undef ) );

    }
    elsif ( $opt eq "stop" ) {

        RemoveInternalTimer($hash);

        Log3 $name, 1,"Voltego_Set $name: Stopped the timer to automatically update readings";
        
        readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
        
        return undef;

    }
    elsif ( $opt eq "interval" ) {

        my $interval = shift @param;

        $interval = 60 unless defined($interval);
        if ( $interval < 5 ) { $interval = 5; }

        Log3 $name, 1, "Voltego_Set $name: Set interval to" . $interval;

        $hash->{INTERVAL} = $interval;
    }

    readingsSingleUpdate( $hash, 'state', 'Initialized', 0 );
    return undef;

}

sub Voltego_Attr(@) {
    return undef;
}

sub Voltego_UpdatePricesCallback($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" )    # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
    {
        Log3 $name, 1,
            "error while requesting "
          . $param->{url}
          . " - $err";    # Eintrag fürs Log
        readingsSingleUpdate( $hash, "state", "ERROR", 1 );
        return undef;
    }

    Log3 $name, 3, "Received non-blocking data from Voltego for prices ";

    Log3 $name, 4, "FHEM -> Voltego: " . $param->{url};
    Log3 $name, 4, "FHEM -> Voltego: " . $param->{message} if ( defined $param->{message} );
    Log3 $name, 4, "Voltego -> FHEM: " . $data;
    Log3 $name, 5, '$err: ' . $err;
    Log3 $name, 5, "method: " . $param->{method};

    if ( !defined($data) or $param->{method} eq 'DELETE' ) {
        return undef;
    }

    eval {
        my $d = decode_json($data) if ( !$err );

        Log3 $name, 5, 'Decoded: ' . Dumper($d);

        if ( defined $d && ref($d) eq "HASH" && defined $d->{errors} ) 
        {
            log 1, Dumper $d;
            
            readingsSingleUpdate( $hash, 'state', "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1 );
            
            return undef;
        }

        my $local_time_zone = DateTime::TimeZone->new( name => 'local' );
        Log3 $name, 5, 'TimeZoneInfo 1: ' . $local_time_zone;
        Log3 $name, 5, 'TimeZoneInfo 2: ' . $local_time_zone->name;

        # Aktuelles Datum und Uhrzeit erhalten
        my $dt  = DateTime->today;
        my $dtt = DateTime->today->add(days => 1);

        # Formatierter Datums- und Uhrzeitstring
        my $today_Day = $dt->strftime('%d'); #01-31
        my $today_Tomorrow = $dtt->strftime('%d'); #01-31
        
        my %prices;
        $prices{0}{'Min'} = undef;
        $prices{0}{'Max'} = undef;
        $prices{1}{'Min'} = undef;
        $prices{1}{'Max'} = undef;

        my $lastModified    = $d->{'last_modified'};
        my $lastModified_Dt = DateTime->from_epoch(epoch => str2time($lastModified), time_zone => 'UTC'); 
        
        $lastModified_Dt->set_time_zone($local_time_zone);

        # Auf die Liste der Elemente zugreifen
        my $elements = $d->{'elements'};

        # Iteriere durch die Elemente und gib den Begin-Zeitpunkt und den Preis aus
        foreach my $element (@$elements) {

            my $begin = $element->{'begin'};
            my $price = $element->{'price'};

            #Log3 $name, 5, "Begin: $begin, Price: $price\n";

            # DateTime-Objekte erstellen
            my $begin_Dt  = DateTime->from_epoch(epoch => str2time($begin), time_zone => $local_time_zone);
            my $begin_Hour = $begin_Dt->strftime('%H'); #00-23
            my $begin_Time = $begin_Dt->strftime('%H:%M'); #00-23:00-59
            my $begin_Day  = $begin_Dt->strftime('%d'); #01-31
            my $fc_Date    = $begin_Dt->ymd; # Retrieves date as a string in 'yyyy-mm-dd' format

            if($today_Day == $begin_Day || $today_Tomorrow == $begin_Day){

                my $index;

                if($today_Day == $begin_Day){
                    $index = 0;
                }
                else {     
                    $index = 1;
                }
              
                $prices{$index}{$begin_Hour} = $price;
                $prices{$index}{$begin_Hour}{'Time'} = $begin_Time;

                $prices{$index}{'Date'} = $fc_Date if ( !defined $prices{$index}{'Date'} );

                if(!defined($prices{$index}{'Min'}) || $price < $prices{$index}{'Min'}){
                    $prices{$index}{'Min'} = $price;
                }

                if(!defined($prices{$index}{'Max'}) || $price > $prices{$index}{'Max'}){
                    $prices{$index}{'Max'} = $price;
                }
            }
        }

        readingsBeginUpdate($hash);

        for my $day (keys(%prices)) {
            
            my $hours = $prices{$day};
           
            for my $hour (keys(%$hours)) {

                my $price = $prices{$day}{$hour};
                my $beginTime = $prices{$day}{$hour}{'Time'};

                my $showEPEXSpot = AttrVal($name, 'showEPEXSpot', 'no');

                if ($showEPEXSpot eq 'yes') {

                    my $reading = 'EPEXSpot_ct_'. $day. '_'. $hour;
                    
                    Log3 $name, 5, 'Generate Reading; '.$reading.' with price: '.$price; 
                    
                    readingsBulkUpdate( $hash, $reading, $price );
                    readingsBulkUpdate( $hash, $reading.'_Time', $beginTime ) if ( defined $beginTime );
                }

                my $showWithTax = AttrVal($name, 'showWithTax', 'no');
                my $taxRate     = AttrVal($name, 'TaxRate', undef);

                if ($showWithTax eq 'yes' && defined($taxRate)){

                    my $reading = 'EPEXSpotTax_ct_'. $day. '_'. $hour;
                    my $priceWithTax = $price * (1 + ($taxRate / 100));

                    Log3 $name, 5, 'Generate Reading; '.$reading.' with price: '.$priceWithTax;

                    readingsBulkUpdate( $hash, $reading, $priceWithTax );
                    readingsBulkUpdate( $hash, $reading.'_Time', $beginTime ) if ( defined $beginTime );
                }

                my $showWithLeviesTaxes = AttrVal($name, 'showWithLeviesTaxes', 'no');
                my $leviesTaxes_ct      = AttrVal($name, 'LeviesTaxes_ct', 0.0);
                my $netCosts_ct         = AttrVal($name, 'NetCosts_ct', 0.0);

                if ($showWithLeviesTaxes eq 'yes' && defined($taxRate)){

                    my $reading = 'TotalPrice_ct_'. $day. '_'. $hour;
                    my $priceTotal = ($price + $leviesTaxes_ct + $netCosts_ct)  * (1 + ($taxRate / 100));

                    Log3 $name, 5, 'Generate Reading; '.$reading.' with price: '.$priceTotal;

                    readingsBulkUpdate( $hash, $reading, $priceTotal );
                    readingsBulkUpdate( $hash, $reading.'_Time', $beginTime ) if ( defined $beginTime );
                }
            }
        }

        readingsBulkUpdate( $hash, "TimeZone",     $local_time_zone->name );
        readingsBulkUpdate( $hash, "LastUpdate",   DateTime->now(time_zone => $local_time_zone)->strftime('%Y-%m-%d %H:%M:%S %z'));
        readingsBulkUpdate( $hash, "LastModified", $lastModified_Dt->strftime('%Y-%m-%d %H:%M:%S %z'));
        readingsBulkUpdate( $hash, "NextUpdate",   DateTime->now(time_zone => $local_time_zone)->add(seconds => InternalVal( $name, 'INTERVAL', 0 ))->strftime('%Y-%m-%d %H:%M:%S %z') );
        
        #Falls nicht verfügbar alte readings löschen
        deleteReadingspec ($hash, "EPEXSpot_ct_0.*") if ( !defined $prices{0}{'Min'} );
        deleteReadingspec ($hash, "EPEXSpot_ct_1.*") if ( !defined $prices{1}{'Min'} );

        deleteReadingspec ($hash, "EPEXSpotTax_ct_0.*") if ( !defined $prices{0}{'Min'} );
        deleteReadingspec ($hash, "EPEXSpotTax_ct_1.*") if ( !defined $prices{1}{'Min'} );

        deleteReadingspec ($hash, "TotalPrice_ct_0.*") if ( !defined $prices{0}{'Min'} );
        deleteReadingspec ($hash, "TotalPrice_ct_1.*") if ( !defined $prices{1}{'Min'} );


        readingsEndUpdate( $hash, 1 );
    };
    
    if ($@) {
        Log3 $name, 1, 'Failure decoding: ' . $@;
    }

    return undef;
}

sub Voltego_UpdateDueToTimer($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    #local allows call of function without adding new timer.
    #must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
    if ( !$hash->{LOCAL} ) {
        RemoveInternalTimer($hash, "Voltego_UpdateDueToTimer");

        InternalTimer( gettimeofday() + InternalVal( $name, 'INTERVAL', undef ),"Voltego_UpdateDueToTimer", $hash );

        readingsSingleUpdate( $hash, 'state', 'Polling', 0 );
    }

    Voltego_RequestUpdate($hash);
}

sub Voltego_HourTaskTimer($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @readings = ( 'EPEXSpot_', 'EPEXSpotTax_', 'TotalPrice_' );

    my $timeZone = DateTime::TimeZone->new(name => 'local');

    # currentTime
    my $currentTime = DateTime->now(time_zone => $timeZone);

    $currentTime = $currentTime->set(minute => 0, second => 0);

    my $currentHour = $currentTime->strftime('%H'); 

    Log3 $name, 5, 'currentHour; '.$currentHour;

    # nextHourTime
    my $nextHourTime = DateTime->now(time_zone => $timeZone);

    $nextHourTime = $nextHourTime->set(minute => 0, second => 0);
    
    $nextHourTime = $nextHourTime->add(hours => 1, minutes => 1);

    my $nextHour = $nextHourTime->strftime('%H'); 

    my $hourTaskTimestamp = $nextHourTime->epoch;

    Log3 $name, 5, 'nextHour; '.$nextHour;
    Log3 $name, 5, 'hourTaskTimestamp; '.$hourTaskTimestamp;

    # previousHourTime
    my $previousHourTime = DateTime->now(time_zone => $timeZone);

    $previousHourTime = $previousHourTime->set(minute => 0, second => 0);

    $previousHourTime = $previousHourTime->subtract(hours => 1);

    my $previousHour = $previousHourTime->strftime('%H');

    Log3 $name, 5, 'previousHour; '.$previousHour;

    for my $reading (@readings){
        
        Log3 $name, 5, 'Reading; '.$reading;

        my $currentPrice  = ReadingsVal($name, $reading.'ct_0_'.$currentHour, undef);
        my $previousPrice = ReadingsVal($name, $reading.'ct_0_'.$previousHour, undef);
        my $nextPrice     = ReadingsVal($name, $reading.'ct_0_'.$nextHour, undef);
        
        my $showCurrentHour  = AttrVal($name, 'showCurrentHour', 'no');
        my $showPreviousHour = AttrVal($name, 'showPreviousHour', 'no');
        my $showNextHour     = AttrVal($name, 'showNextHour', 'no');

        if ($showCurrentHour eq 'yes' && defined $currentPrice){

            Log3 $name, 5, 'currentPrice; '.$currentPrice;

            Log3 $name, 5, 'Generate Reading; '.$reading."Current_ct";
            Log3 $name, 5, 'Generate Reading; '.$reading."Current_h";

            readingsBeginUpdate($hash);

            readingsBulkUpdate( $hash, $reading."Current_ct", $currentPrice);
            readingsBulkUpdate( $hash, $reading."Current_h",  $currentHour);
            
            readingsEndUpdate($hash, 1 );
        }   

        if ($showPreviousHour eq 'yes' && defined $previousPrice){

            Log3 $name, 5, 'previousPrice; '.$previousPrice;

            Log3 $name, 5, 'Generate Reading; '.$reading."Previous_ct";
            Log3 $name, 5, 'Generate Reading; '.$reading."Previous_h";

            readingsBeginUpdate($hash);

            readingsBulkUpdate( $hash, $reading."Previous_ct", $previousPrice);
            readingsBulkUpdate( $hash, $reading."Previous_h",  $previousHour);
            
            readingsEndUpdate($hash, 1 );
        } 

        if ($showNextHour eq 'yes' && defined $nextPrice){

            Log3 $name, 5, 'nextPrice; '.$nextPrice;

            Log3 $name, 5, 'Generate Reading; '.$reading."Next_ct";
            Log3 $name, 5, 'Generate Reading; '.$reading."Next_h";

            readingsBeginUpdate($hash);

            readingsBulkUpdate( $hash, $reading."Next_ct", $nextPrice);
            readingsBulkUpdate( $hash, $reading."Next_h",  $nextHour);
            
            readingsEndUpdate($hash, 1 );
        } 
    }

    #local allows call of function without adding new timer.
    #must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
    if ( !$hash->{LOCAL} ) {

        RemoveInternalTimer($hash, "Voltego_HourTaskTimer");

        InternalTimer( $hourTaskTimestamp, "Voltego_HourTaskTimer", $hash );
    }
}

sub Voltego_RequestUpdate($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if ( not defined $hash ) {
        Log3 'Voltego', 1,
          "Error on Voltego_RequestUpdate. Missing hash variable";
        return undef;
    }

    Log3 $name, 4, "Voltego_RequestUpdate Called for non-blocking value update. Name: $name";

    my $CurrentTokenData = Voltego_LoadToken($hash);

    # Aktuelles Datum und Uhrzeit erhalten
    my $dt = DateTime->now;

    my $local_time_zone = DateTime::TimeZone->new( name => 'local' );
    my $time_zone = $local_time_zone->name;
        
    Log3 $name, 5, 'TimeZoneInfo 1: ' . $local_time_zone;
    Log3 $name, 5, 'TimeZoneInfo 2: ' . $time_zone;
    
    # Beispiel für ein benutzerdefiniertes Format
    my $format = '%Y-%m-%dT00:00:00'; #2023-11-24T00:00:00

    # Formatierter Datums- und Uhrzeitstring
    my $formatted_date = $dt->strftime($format);

    my $getPriceValueUrl = $url{"getPriceValue"};

	$getPriceValueUrl =~ s/#fromDate#/$formatted_date/g;

    $getPriceValueUrl =~ s/#TimeZone#/$time_zone/g;

    my $request = {
        url    => $getPriceValueUrl,
        header => {
            "Content-Type"  => "application/json;charset=UTF-8",
            "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
        },
        method   => 'GET',
        timeout  => 2,
        hideurl  => 1,
        callback => \&Voltego_UpdatePricesCallback,
        hash     => $hash
    };

    Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

    HttpUtils_NonblockingGet($request);
}


sub Voltego_encrypt($) {
    my ($decoded) = @_;
    my $key = getUniqueId();
    my $encoded;

    return $decoded if ( $decoded =~ /crypt:/ );

    for my $char ( split //, $decoded ) {
        my $encode = chop($key);
        $encoded .= sprintf( "%.2x", ord($char) ^ ord($encode) );
        $key = $encode . $key;
    }

    return 'crypt:' . $encoded;
}

sub Voltego_decrypt($) {
    my ($encoded) = @_;
    my $key = getUniqueId();
    my $decoded;

    return $encoded if ( $encoded !~ /crypt:/ );

    $encoded = $1 if ( $encoded =~ /crypt:(.*)/ );

    for my $char ( map { pack( 'C', hex($_) ) } ( $encoded =~ /(..)/g ) ) {
        my $decode = chop($key);
        $decoded .= chr( ord($char) ^ ord($decode) );
        $key = $decode . $key;
    }

    return $decoded;
}

################################################################
#    alle Readings eines Devices oder nur Reading-Regex
#    löschen
################################################################
sub deleteReadingspec {
    my $hash = shift;
    my $spec = shift // ".*";

    my $readingspec = '^'.$spec.'$';

    for my $reading ( grep { /$readingspec/x } keys %{$hash->{READINGS}} ) {
        readingsDelete($hash, $reading);
    }

    return;
}

1;

=pod
=begin html

<a name="Voltego"></a>
<h3>Voltego</h3>
<ul>
    <i>Voltego</i> implements an interface to the Voltego energy price api. 
    <br>The plugin can be used to read the hourly energy proces from the Voltego website.
    <br>The following features / functionalities are defined by now when using Voltego:
    <br>
    <a name="Voltegodefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; Voltego &lt;clientId&gt; &lt;clientSecret&gt; &lt;interval&gt;</code>
        <br>
        <br> Example: <code>define Voltego Voltego 42 someclientSecret 6ßßß</code>
        <br>
        <br> The client id and the client secret can be requested by a short e-mail to backoffice@voltego.de. See <a>voltego.de</a> for more information
    </ul>
    <br>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The <i>set</i> command just offers very limited options. If can be used to control the refresh mechanism. The plugin only evaluates the command. Any additional information is ignored.
        <br>
        <br> Options:
        <ul>
            <li><i>interval</i>
                <br> Sets how often the values shall be refreshed. This setting overwrites the value set during define.</li>
            <li><i>start</i>
                <br> (Re)starts the automatic refresh. Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
            <li><i>stop</i>
                <br> Stops the automatic polling used to refresh all values.</li>
        </ul>
    </ul>
    <br>
    <a name="Voltegoget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> You can <i>get</i> the major information from the Voltego cloud.
        <br>
        <br> Options:
        <ul>
           <li><i>update</i>
                <br> This command triggers a single update of the hourly energy prices.
            </li>
            <li><i>newToken</i>
                <br> This command forces to get a new oauth token.</li>
        </ul>
    </ul>
    <br>
        <a name="Voltegoattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> You can change the behaviour of the Voltego Device.
        <br>
        <br> Attributes:
        <ul>
            <li><i>showEPEXSpot</i>
                <br> When set to <i>yes</i>, reading <i>EPEXSpot_ct_?_??</i> are generated
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no readings for <i>EPEXSpot_ct_?_??</i> will be generated..</b>
            </li>
            <li><i>showWithTax</i>
                <br> When set to <i>yes</i>, reading <i>EPEXSpotTax_ct_?_??</i> are generated
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no readings for <i>EPEXSpotTax_ct_?_??</i> will be generated..</b>
            </li>
            <li><i>showWithLeviesTaxes</i>
                <br> When set to <i>yes</i>, reading <i>TotalPrice_ct_?_??</i> are generated
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no readings for <i>TotalPrice_ct_?_??</i> will be generated..</b>
            </li>

            <li><i>TaxRate</i>
                <br> Tex rate in precentage, used fpr calculating prices with tax <i>EPEXSpotTax_ct_?_??</i> or <i>TotalPrice_ct_?_??</i>.
                <br/> 
            </li>
            <li><i>LeviesTaxes_ct</i>
                <br> Levies and taxes in cents, used fpr calculating <i>TotalPrice_ct_?_??</i>.
            </li>
            <li><i>NetCosts_ct</i>
                <br>Netcosts in cents (without tax), used fpr calculating <i>TotalPrice_ct_?_??</i>.
            </li>
        </ul>
 	</ul>
    <br>
    <a name="Voltegoreadings"></a>
    <b>Generated Readings:</b>
		<br>
    <ul>
        <ul>
            <li><b>LastModified</b>
                <br> Time when the energy prices were last updated by Voltego
            </li>
            <li><b>LastUpdate</b>
                <br> Indicates when the last successful request to update the energy prices was made</i>.
            </li>
            <li><b>NextUpdate</b>
                <br>Time when the energy prices will next be queried from Voltego
            </li>
            <li><b>EPEXSpot_ct_0_00 .. EPEXSpot_ct_0_23</b>
                <br> Energy price in cents for today per hour EPEXSpot_ct_0_&lt;hour&gt;
            </li>
            <li><b>EPEXSpot_ct_1_00 .. EPEXSpot_ct_1_23</b>
                <br>Energy price in cents for tommorow per hour EPEXSpot_ct_1_&lt;hour&gt; when available
            </li>
            <li><b>EPEXSpotTax_ct_0_00 .. EPEXSpotTax_ct_0_23</b>
                <br> Energy price including tax in cents for today per hour EPEXSpotTax_ct_0_&lt;hour&gt;
            </li>
            <li><b>EPEXSpotTax_ct_1_00 .. EPEXSpotTax_ct_1_23</b>
                <br>Energy price including taxin cents for tommorow per hour EPEXSpotTax_ct_1_&lt;hour&gt; when available
            </li>
             <li><b>TotalPrice_ct_0_00 .. TotalPrice_ct_0_23</b>
                <br> Energy price including tax, net costs and levies in cents for today per hour TotalPrice_ct_0_&lt;hour&gt;
            </li>
            <li><b>TotalPrice_ct_1_00 .. TotalPrice_ct_1_23</b>
                <br>Energy price including tax, net costs and levies in cents for tommorow per hour TotalPrice_ct_1_&lt;hour&gt; when available
            </li>
            <li><b>TimeZone</b>
                <br> Time zone used for display and evaluation
            </li>
        </ul>
    </ul>
</ul>

=end html

=cut
