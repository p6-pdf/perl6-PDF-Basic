use v6;

class X::PDF::Image::WrongHeader is Exception {
    has Str $.type is required;
    has Str $.header is required;
    has $.path is required;
    method message {
        "{$!path} image doesn't have a {$!type} header: {$.header.perl}"
    }
}

class X::PDF::Image::UnknownType is Exception {
    has $.path is required;
    method message {
        die "unable to open image: $!path";
    }
}

class PDF::Content::Image {
    use PDF::DAO;
    method network-endian { True }

    #| lightweight replacement for deprecated $buf.unpack
    method unpack($buf, *@templ ) {
	my @bytes = $buf.list;
        my Bool \nw = $.network-endian;
        my uint $off = 0;

	@templ.map: {
	    my uint $size = .^nativesize div 8;
	    my uint $v = 0;
            my uint $i = nw ?? 0 !! $size;
            for 1 .. $size {
                $v +<= 8;
                $v += @bytes[$off + (nw ?? $i++ !! --$i)];
	    }
            $off += $size;

	    $v;
	}
    }

    method !image-type($_, :$path!) {
        when m:i/^ jpe?g $/    { 'JPEG' }
        when m:i/^ gif $/      { 'GIF' }
        when m:i/^ png $/      { 'PNG' }
        when m:i/^ pdf|json $/ { 'PDF' }
        default {
            die X::PDF::Image::UnknownType.new( :$path );
        }
    }

    multi method open(Str $data-uri where /^('data:' [<t=.ident> '/' <s=.ident>]? $<b64>=";base64"? $<start>=",") /) {
        use Base64;
        use PDF::IO::Input;
        my $path = ~ $0;
        my Str \mime-type = ( $0<t> // '(missing)').lc;
        my Str \mime-subtype = ( $0<s> // '').lc;
        my Bool \base64 = ? $0<b64>;
        my Numeric \start = $0<start>.to;

        die "expected mime-type 'image/*' or 'application/pdf', got '{mime-type}': $path"
            unless mime-type eq (mime-subtype eq 'pdf' ?? 'application' !! 'image');
        my $image-type = self!image-type(mime-subtype, :$path);
        my $data = substr($data-uri, start);
        $data = decode-base64($data, :bin).decode("latin-1")
            if base64;

        my $fh = PDF::IO::Input.coerce($data, :$path);
        self!open($image-type, $fh, :$data-uri);
    }

    multi method open(Str $path! ) {
        self.open( $path.IO );
    }

    multi method open(IO::Path $io-path) {
        self.open( $io-path.open( :r, :enc<latin-1>) );
    }

    multi method open(IO::Handle $fh!) {
        my $path = $fh.path;
        my Str $type = self!image-type($path.extension, :$path);
        self!open($type, $fh);
    }

    method !open(Str $type, $fh, |c) {
        my \image = (require ::('PDF::Content::Image')::($type)).read($fh);
        my Numeric $width;
        my Numeric $height;
        given image<Subtype> {
                when 'Image' {
                    $width = image<Width>;
                    $height = image<Height>
                }
                when 'Form' {
                    my $bbox = image<BBox>;
                    $width = $bbox[2] - $bbox[0];
                    $height = $bbox[3] - $bbox[1];
                }
                default {
                    die "not an XObject Image";
                }
            }

        self!add-details(image, :$fh, :$type, :$width, :$height, |c);
    }

    method !add-details($obj, :$fh!, :$type!, :$width!, :$height!, :$data-uri) {
        my subset Str-or-IOHandle of Any where Str|IO::Handle;
        my role Details[Str-or-IOHandle $source, Str $type, $width, $height] {
            method width  { $width }
            method height { $height }
            method image-type { $type }
            has Str $.data-uri is rw;
            method data-uri is rw {
                Proxy.new(
                    FETCH => sub ($) {
                        $!data-uri //= do {
                            use Base64;
                            my $raw = do with $source {
                                .isa(Str)
                                    ?? .substr(0)
                                    !! .path.IO.slurp(:bin);
                            }
                            my $enc = encode-base64($raw, :str);
                            sprintf 'data:image/%s;base64,%s', $type.lc, $enc;
                        }
                    },
                    STORE => sub ($, $!data-uri) {},
                )
            }
        }
        $obj does Details[$fh, $type, $width, $height];
        $obj.data-uri = $_ with $data-uri;
        $obj;
    }

    method inline-to-xobject(Hash $inline-dict, Bool :$invert) {

        my constant %Abbreviations = %(
            # [PDF 1.7 TABLE 4.43 Entries in an inline image object]
            :BPC<BitsPerComponent>,
            :CS<ColorSpace>,
            :D<Decode>,
            :DP<DecodeParms>,
            :F<Filter>,
            :H<Height>,
            :IM<ImageMask>,
            :I<Interpolate>,
            :W<Width>,
            # [PDF 1.7 TABLE 4.44 Additional abbreviations in an inline image object]
            :G<DeviceGray>,
            :RGB<DeviceRGB>,
            :CMYK<DeviceCMYK>,
            # Notes:
            # 1. Ambiguous 'Indexed' entry seems to be a typo in the spec
            # 2. filter abbreviations are handled in PDF::IO::Filter
            );

        my $alias = $invert ?? %Abbreviations.invert.Hash !! %Abbreviations;

        my %xobject-dict = $inline-dict.pairs.map: {
            ($alias{.key} // .key) => .value
        }

        %xobject-dict;
    }

    method inline-content {

        # for serialization to content stream ops: BI dict ID data EI
        use PDF::Content::Ops :OpCode;
        use PDF::DAO::Util :to-ast-native;
        # serialize to content ops
        my %dict = to-ast-native(self).value.list;
        %dict<Type Subtype Length>:delete;
        %dict = self.inline-to-xobject( %dict, :invert );

        [ (BeginImage) => [ :%dict ],
          (ImageData)  => [ :$.encoded ],
          (EndImage)   => [],
        ]
    }

}
