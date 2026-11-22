package tls

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:time"

// A certificate that certificate_make writes and signs with ECDSA P-256 and SHA-256.
Certificate_Desc :: struct {
    names:[]string, // its dNSNames; the first is also the common name of its subject
    public_key:[]u8, // the subject's P-256 key, uncompressed
    not_before,not_after:time.Time,
    issuer:^ecdsa.Private_Key, // a P-256 key; the subject's own for a self-signed certificate
    issuer_name:string, // the common name of the issuer; "" for a self-signed one
    authority:bool, // a CA, which signs other certificates
    extensions:[][]u8, // DER Extensions after its subjectAltName
}

// The DER of a certificate, in allocator.
certificate_make :: proc(desc:Certificate_Desc,allocator:=context.allocator) -> (der:[]u8,err:Error) {
    if len(desc.names)==0 || desc.issuer==nil || ecdsa.curve(desc.issuer)!=.SECP256R1 || len(desc.public_key)!=65 {return nil,.Bad_Config}
    if time.diff(desc.not_before,desc.not_after)<=0 {return nil,.Bad_Config}
    own:[3][]u8
    count:=0
    defer for e in own[:count] {delete(e,allocator)}
    e:x509.Error
    if desc.authority {
        own[count],e=x509.marshal_ext_basic_constraints(true,-1,true,allocator)
        if e!=.None {return nil,x509_failure(e)}
        count+=1
        own[count],e=x509.marshal_ext_key_usage({.Key_Cert_Sign,.CRL_Sign,.Digital_Signature},true,allocator)
        if e!=.None {return nil,x509_failure(e)}
        count+=1
    }
    own[count],e=x509.marshal_ext_san(desc.names,nil,false,allocator)
    if e!=.None {return nil,x509_failure(e)}
    count+=1
    extensions,merr:=make([][]u8,count+len(desc.extensions),allocator)
    if merr!=nil {return nil,.Out_Of_Memory}
    defer delete(extensions,allocator)
    copy(extensions,own[:count])
    copy(extensions[count:],desc.extensions)

    serial:[16]u8
    crypto.rand_bytes(serial[:])
    serial[0]=serial[0]&0x7f|0x01
    subject:=[]x509.DN_Attribute{{type=.Common_Name,value=desc.names[0]}}
    issuer:=[]x509.DN_Attribute{{type=.Common_Name,value=desc.issuer_name if desc.issuer_name!="" else desc.names[0]}}
    tbs:[]u8
    tbs,e=x509.marshal_tbs_certificate({
        serial=serial[:],
        signature_algorithm=.ECDSA_SHA256,
        issuer=issuer,
        not_before=desc.not_before,
        not_after=desc.not_after,
        subject=subject,
        public_key={algorithm=.ECDSA_P256,ec_point=desc.public_key},
        extensions=extensions,
    },allocator)
    if e!=.None {return nil,x509_failure(e)}
    defer delete(tbs,allocator)
    signature,signed:=ecdsa.sign_asn1(desc.issuer,.SHA256,tbs,allocator)
    if !signed {return nil,.Out_Of_Memory}
    defer delete(signature,allocator)
    der,e=x509.marshal_certificate(tbs,.ECDSA_SHA256,signature,allocator)
    if e!=.None {return nil,x509_failure(e)}
    return der,nil
}

@(private)
x509_failure :: proc(e:x509.Error) -> Error {
    return .Out_Of_Memory if e==.Allocation_Failed else .Bad_Config
}
