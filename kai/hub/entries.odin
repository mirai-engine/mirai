package hub

import "mirai:kai"

// GET /api/entries: the bytes of an entry and of the bodies a browser writes,
// from the types the logs read, so a client checks every field of a draft
// before it signs. Integers are little-endian; structures are packed.

@(private)
Field :: struct {name:string,offset:uintptr,size:int,text:string}

@(private)
layout_write :: proc(j:^Json,name:string,size:int,fields:[]Field,tail:string) {
    json_key(j,name)
    json_object(j)
    json_member_int(j,"size",i64(size))
    json_key(j,"fields")
    json_array(j)
    for f in fields {
        json_object(j)
        json_member_string(j,"name",f.name)
        json_member_int(j,"offset",i64(f.offset))
        json_member_int(j,"size",i64(f.size))
        json_member_string(j,"text",f.text)
        json_end_object(j)
    }
    json_end_array(j)
    json_member_string(j,"then",tail)
    json_end_object(j)
}

@(private)
route_entries :: proc(c:^Call) {
    H :: kai.Entry_Head
    j:=json_make()
    json_object(&j)
    layout_write(&j,"entry",size_of(H),{
        {"magic",offset_of(H,magic),size_of(u32),"u32 'KAI1' as bytes K A I 1"},
        {"version",offset_of(H,version),size_of(u16),"u16"},
        {"kind",offset_of(H,kind),1,"u8: the entry's type, its value in types"},
        {"parents",offset_of(H,parents),1,"u8: how many parent addresses follow the head, at most ENTRY_PARENTS_MAX"},
        {"log_id",offset_of(H,log_id),32,"the log: zero in a genesis"},
        {"author",offset_of(H,author),32,"a device's Ed25519 key, the recovery key, or a passkey's web key id: BLAKE3 of u16 length of the COSE key || COSE key || rp_id"},
        {"author_ctx",offset_of(H,author_ctx),32,"an entry of the author's User_Log; for a passkey, its Web_Key_Add or a later one"},
        {"time",offset_of(H,time),8,"i64 nanoseconds since 1970"},
        {"body_len",offset_of(H,body_len),4,"u32"},
        {"sig_kind",offset_of(H,sig_kind),1,"u8: 0 Ed25519, 1 WebAuthn"},
        {"reserved",offset_of(H,reserved),3,"zero"},
    },"parents × 32-byte addresses ascending, then the body: the unsigned bytes end here. Ed25519: a 64-byte signature over them follows. WebAuthn: u16 length and the assertion: Assertion_Head {cose u16, rp u8, authenticator u16, client u16, signature u8} then the COSE key, the rp_id, authenticatorData, clientDataJSON and the signature; the challenge it signs is BLAKE3-256 of the unsigned bytes, base64url in clientDataJSON. An entry's address is BLAKE3-256 of all its bytes.")
    json_key(&j,"constants")
    json_object(&j)
    json_member_int(&j,"magic",i64(kai.KAI_MAGIC))
    json_member_int(&j,"version",kai.VERSION)
    json_member_int(&j,"ENTRY_PARENTS_MAX",kai.ENTRY_PARENTS_MAX)
    json_member_int(&j,"ENTRY_BODY_MAX",kai.ENTRY_BODY_MAX)
    json_member_string(&j,"LABEL_DEVICE",kai.LABEL_DEVICE)
    json_member_string(&j,"LABEL_WEB_LOGIN",LABEL_WEB_LOGIN)
    json_end_object(&j)
    json_key(&j,"types")
    json_object(&j)
    types:=TYPE_TEXT
    for t in kai.Entry_Type {
        if t!=.None {json_member_int(&j,types[t],i64(t))}
    }
    json_end_object(&j)
    json_key(&j,"enums")
    json_object(&j)
    json_key(&j,"role")
    json_object(&j)
    roles:=ROLE_TEXT
    for r in kai.Role {json_member_int(&j,roles[r],i64(r))}
    json_end_object(&j)
    json_key(&j,"verdict")
    json_object(&j)
    verdicts:=VERDICT_TEXT
    for v in kai.Verdict_Kind {json_member_int(&j,verdicts[v],i64(v))}
    json_end_object(&j)
    json_key(&j,"anchor")
    json_object(&j)
    anchors:=ANCHOR_TEXT
    for a in kai.Anchor_Kind {json_member_int(&j,anchors[a],i64(a))}
    json_end_object(&j)
    json_end_object(&j)
    json_key(&j,"bodies")
    json_object(&j)
    {
        B :: kai.User_Genesis_Body
        layout_write(&j,"user_genesis",size_of(B),{
            {"recovery",offset_of(B,recovery),32,"the recovery key, Ed25519: the genesis's author"},
            {"device",offset_of(B,device),32,"the first device's Ed25519 key"},
            {"dh",offset_of(B,dh),32,"the first device's X25519 key"},
            {"proof",offset_of(B,proof),64,"the device's Ed25519 signature over LABEL_DEVICE || recovery"},
        },"the user's name, 1 to NAME_MAX bytes of UTF-8. The genesis has no parents, a zero log_id and a zero author_ctx; the log's id is its address. The recovery key is shown once as recovery_encode does: Crockford Base32 (0123456789ABCDEFGHJKMNPQRSTVWXYZ) of the 32-byte seed followed by the first 3 bytes of BLAKE3('kai-1/recovery' || seed), most significant bits first, in groups of four digits joined by '-'.")
    }
    {
        B :: kai.Web_Key_Add_Body
        layout_write(&j,"web_key_add",size_of(B),{
            {"credential",offset_of(B,credential),1,"u8: bytes of the credential id"},
            {"cose",offset_of(B,cose),2,"u16: bytes of the COSE key (Ed25519 alg -8 or P-256 alg -7)"},
            {"rp",offset_of(B,rp),1,"u8: bytes of the relying party id"},
        },"the credential id, the COSE key, the rp_id; signed by the recovery key or a device of the user")
    }
    {
        B :: kai.Proposal_Comment_Body
        A :: kai.Comment_Anchor
        anchor:=offset_of(B,anchor)
        layout_write(&j,"proposal_comment",size_of(B),{
            {"reply_to",offset_of(B,reply_to),32,"the comment it answers, or zero"},
            {"anchor.kind",anchor+offset_of(A,kind),1,"u8: anchor kind"},
            {"anchor.path",anchor+offset_of(A,path),2,"u16: bytes of the path that follows"},
            {"anchor.line",anchor+offset_of(A,line),4,"u32: lines: the first line, from 1"},
            {"anchor.lines",anchor+offset_of(A,lines),4,"u32: lines: how many"},
            {"anchor.key",anchor+offset_of(A,key),8,"u64: zero from a browser"},
            {"anchor.field",anchor+offset_of(A,field),8,"u64: zero from a browser"},
            {"anchor.change",anchor+offset_of(A,change),16,"the change it is on, zero for the whole proposal"},
        },"the path, then the text (UTF-8) to the end of the body")
    }
    {
        B :: kai.Proposal_Verdict_Body
        layout_write(&j,"proposal_verdict",size_of(B),{
            {"verdict",offset_of(B,verdict),1,"u8: verdict"},
            {"revision",offset_of(B,revision),32,"the head revision of the stack it binds to"},
        },"nothing")
    }
    layout_write(&j,"proposal_close",0,{},"an empty body")
    layout_write(&j,"proposal_reopen",0,{},"an empty body")
    {
        B :: kai.Member_Body
        layout_write(&j,"member_add",size_of(B),{
            {"user",offset_of(B,user),32,"the user"},
            {"role",offset_of(B,role),1,"u8: role, reader to admin"},
        },"nothing; role_set is the same")
        layout_write(&j,"role_set",size_of(B),{
            {"user",offset_of(B,user),32,"the member"},
            {"role",offset_of(B,role),1,"u8: role, reader to admin"},
        },"nothing")
    }
    {
        B :: kai.Subject_Body
        layout_write(&j,"member_remove",size_of(B),{
            {"subject",offset_of(B,subject),32,"the member's user"},
        },"nothing")
    }
    json_end_object(&j)
    json_end_object(&j)
    json_response(c,&j)
}
