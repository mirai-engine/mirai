package api

import "core:strings"
import "core:testing"

// A search of the documentation gives the sections that say its words, those
// that say more of them first, each with the command that reads it.
@(test)
a_search_of_the_documentation_finds_the_sections_that_say_its_words :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    text,ok:=docs_search(".","content tool")
    if !testing.expectf(t,ok,"%s",text) {return}
    first:=text[:strings.index_byte(text,'\n')]
    testing.expectf(t,strings.contains(first,"content-tool"),"the page of the content tool comes first:\n%s",text)
    testing.expect(t,strings.count(text,"\nmirai docs ")<DOCS_FOUND,"at most DOCS_FOUND sections")
    _,found:=docs_search(".","xyzzy_never_said")
    testing.expect(t,!found,"words no section says find nothing")
    answer,answered:=docs_tool_answer(".",`{"search":"content tool"}`)
    testing.expect(t,answered && strings.has_prefix(answer,"mirai docs "),answer)
}
