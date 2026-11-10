package project

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
COMMIT_A :: "0123456789abcdef0123456789abcdef01234567"

@(test)
sources_round_trip_and_write_only_the_ones_there :: proc(t:^testing.T) {
    m:=manifest_default("Game")
    base.text_set(m.plugins[0][:],"unreal")
    base.text_set(m.sources[0].name[:],"unreal")
    base.text_set(m.sources[0].url[:],"https://github.com/tomaszbk/mirai-unreal.git")
    base.text_set(m.sources[0].commit[:],COMMIT_A)
    text:=manifest_text(&m,context.temp_allocator)
    testing.expect(t,strings.contains(text,"\"sources\": [\n    {\n      \"name\": \"unreal\",\n      \"url\": \"https://github.com/tomaszbk/mirai-unreal.git\",\n      \"commit\": \""+COMMIT_A+"\",\n      \"catalog\": false\n    }\n  ],"),text)
    back,error:=manifest_parse(text)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,back==m)
    found:=source_find(&back,"unreal")
    testing.expect(t,found!=nil && base.text_get(found.commit[:])==COMMIT_A)
    testing.expect(t,source_find(&back,"physics")==nil)

    empty:=manifest_default("Game")
    testing.expect(t,strings.contains(manifest_text(&empty,context.temp_allocator),"\"sources\": [],"))
    // A manifest written before there were sources reads.
    old,old_error:=manifest_parse(`{"name": "Game", "plugins": ["physics"]}`)
    testing.expect_value(t,old_error.code,Error_Code.None)
    testing.expect(t,source_find(&old,"physics")==nil)
}

@(test)
a_source_needs_a_url_and_a_full_commit :: proc(t:^testing.T) {
    cases:=[?]struct{text:string,code:Error_Code}{
        {`{"name": "G", "sources": [{"name": "a", "url": "u", "commit": "` + COMMIT_A + `"}]}`,.None},
        {`{"name": "G", "sources": [{"name": "a", "url": "", "commit": "` + COMMIT_A + `"}]}`,.Source_Invalid},
        {`{"name": "G", "sources": [{"name": "a", "url": "u", "commit": "0123abc"}]}`,.Source_Invalid},
        {`{"name": "G", "sources": [{"name": "a", "url": "u", "commit": "0123456789ABCDEF0123456789ABCDEF01234567"}]}`,.Source_Invalid},
        {`{"name": "G", "sources": [{"name": "A", "url": "u", "commit": "` + COMMIT_A + `"}]}`,.Name_Invalid},
        {`{"name": "G", "sources": [{"name": "a", "url": "u", "commit": "` + COMMIT_A + `"}, {"name": "a", "url": "v", "commit": "` + COMMIT_A + `"}]}`,.Name_Repeated},
        {`{"name": "G", "sources": [{"url": "u", "commit": "` + COMMIT_A + `"}]}`,.Name_Missing},
    }
    for c in cases {
        _,error:=manifest_parse(c.text)
        testing.expectf(t,error.code==c.code,"%s: %v, not %v",c.text,error.code,c.code)
    }
}

@(test)
a_catalog_lists_a_file_for_each_plugin_at_a_reviewed_commit :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-catalog-*",context.temp_allocator)
    testing.expect(t,error==nil)
    defer base.remove_all(folder)
    c:=new(Catalog,context.temp_allocator)
    testing.expect_value(t,catalog_read(path(folder,"missing",allocator=context.temp_allocator),c).code,Error_Code.Not_Found)
    // A catalog without plugins yet has no folder for them.
    testing.expect_value(t,catalog_read(folder,c).code,Error_Code.None)
    testing.expect_value(t,catalog_count(c),0)

    write :: proc(t:^testing.T,folder,file,text:string) {
        testing.expect(t,os.make_directory_all(path(folder,CATALOG_PLUGINS,allocator=context.temp_allocator))==nil || os.is_dir(path(folder,CATALOG_PLUGINS,allocator=context.temp_allocator)))
        testing.expect(t,os.write_entire_file(path(folder,CATALOG_PLUGINS,file,allocator=context.temp_allocator),text)==nil)
    }
    weather:=`{
  "description": "",
  "url": "https://github.com/someone/mirai-weather.git",
  "commit": "` + COMMIT_A + `"
}
`
    write(t,folder,"weather.json",weather)
    write(t,folder,"unreal.json",`{"description": "Imports Unreal editor packages", "url": "https://github.com/tomaszbk/mirai-unreal.git", "commit": "` + COMMIT_A + `"}`)
    write(t,folder,"README.md","Not a plugin")
    testing.expect_value(t,catalog_read(folder,c).code,Error_Code.None)
    testing.expect_value(t,catalog_count(c),2)
    testing.expect_value(t,base.text_get(c.plugins[0].name[:]),"unreal")
    entry:=catalog_find(c,"weather")
    testing.expect(t,entry!=nil && base.text_get(entry.url[:])=="https://github.com/someone/mirai-weather.git")
    testing.expect(t,catalog_find(c,"physics")==nil)
    testing.expect_value(t,catalog_entry_text(entry,context.temp_allocator),weather)

    // The file that is wrong is the one named.
    write(t,folder,"broken.json",`{"url": "u", "commit": "abc"}`)
    broken:=catalog_read(folder,c)
    testing.expect_value(t,broken.code,Error_Code.Source_Invalid)
    testing.expect_value(t,base.text_get(broken.subject[:]),"broken")
    os.remove(path(folder,CATALOG_PLUGINS,"broken.json",allocator=context.temp_allocator))
    write(t,folder,"Upper.json",`{"url": "u", "commit": "` + COMMIT_A + `"}`)
    testing.expect_value(t,catalog_read(folder,c).code,Error_Code.Name_Invalid)
}
