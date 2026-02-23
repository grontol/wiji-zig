// fn main() {
//     a()
//     a(10)
//     a(10, 30)
//     a(
//         10,
//         40,
//     )
    
//     foo(x)
    
//     fn foo(self: *Self, x: i32) {
        
//     }
    
//     val x = 10
//     var y = 10
//     const z = 10
    
//     val simp: i32
//     val arr: []i32
//     val tuple: (i32, []i32, &Foo)
//     val generic: Foo<Bar, i32, []i32>
//     val nullable: ?i32
    
//     val x = 10
//     x = 2
//     x += 3
//     x *= 4
//     x -= 5
//     x /= 6
//     x %= 7
    
//     1 + 2
//     1 + 2 * 3
//     (1 + 2) * 3
//     4 % 3 * 3 / 10 + (2 - 4)
    
//     if x foo()
//     if a < 20 foo() else goo()
//     if a < 20 foo() else if a < 50 hoo() else goo()
    
//     val x = if foo() 10 else 20
    
//     if (a + 4) > 10 {
//         foo()
//         hoo()
//     }
//     else {
//         goo()
//     }
    
//     for a foo()
    
//     for a in 0..x {
//         foo(a)
//     }
    
//     for a, i in 0..x {
//         foo(a, i)
//     }
    
//     for a, i in 0..x foo(a, i)
    
//     val a = .[]
//     val x: []i32 = .[1, 2, 3]
//     val y = x[a + 2]
//     val y = x[a + 2][b + 2]
// }

struct Person {
    name: string
    age: i32 = 69
    
    fn go(self: &Person) {
        self.name = "FOO"
    }
}

// fn main() {
//     val p = Person.{
//         name = "Koko",
//         age = 20,
//     }
    
//     val p2: Person = .{ "Jojo", 10 }
    
//     val x = p.name.foo.x
//     p.go()
// }

fn main(argv: []string) {
    val x: i32 = 10
    var y = 20
    const z = 30
    
    const f = 0.34
    const s = "STR"
    const c = '\n'
    const c2 = '\r'
    const c3 = '\t'
    const c4 = '\''
    const c5 = '\\'
    const b = f
}

fn foo(): i32 {
    return 0
}