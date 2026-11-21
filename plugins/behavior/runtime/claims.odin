package behavior

import "mirai:core"
import "mirai:std/ai"

@(storage,shared)
Claims :: struct {
    using reservations:ai.Reservations,
}

attack_token :: proc "contextless" (target:core.Entity) -> ai.Reservation_Key {
    return {u64(target),0}
}

smart_key :: proc "contextless" (found:Smart_Found) -> ai.Reservation_Key {
    if found.object==core.NONE || found.offer<0 || found.offer>=SMART_OFFERS {return {}}
    return {u64(found.object),u16(found.offer+1)}
}

claim_take :: proc "contextless" (
    claims:^Claims,key:ai.Reservation_Key,holder:core.Entity,limit:int,time:core.Time,
    lease:u64=1,priority:u8=0,
) -> bool {
    return claims!=nil && ai.reserve_take(&claims.reservations,key,u64(holder),limit,time.tick,lease,priority)
}

claim_open :: proc "contextless" (
    claims:^Claims,key:ai.Reservation_Key,holder:core.Entity,limit:int,time:core.Time,priority:u8=0,
) -> bool {
    return claims!=nil && ai.reserve_open(&claims.reservations,key,u64(holder),limit,time.tick,priority)
}

claim_held :: proc "contextless" (claims:^Claims,key:ai.Reservation_Key,holder:core.Entity,time:core.Time) -> bool {
    return claims!=nil && ai.reserve_holds(&claims.reservations,key,u64(holder),time.tick)
}

claim_renew :: proc "contextless" (
    claims:^Claims,key:ai.Reservation_Key,holder:core.Entity,time:core.Time,lease:u64=1,
) -> bool {
    if !claim_held(claims,key,holder,time) {return false}
    ai.reserve_renew(&claims.reservations,key,u64(holder),time.tick,lease)
    return true
}

claim_use :: proc "contextless" (claims:^Claims,key:ai.Reservation_Key,holder:core.Entity,time:core.Time) -> bool {
    if !claim_held(claims,key,holder,time) {return false}
    ai.reserve_use(&claims.reservations,key,u64(holder))
    return true
}

claim_release :: proc "contextless" (claims:^Claims,key:ai.Reservation_Key,holder:core.Entity) {
    if claims!=nil {ai.reserve_release(&claims.reservations,key,u64(holder))}
}
