struct Person {
    name: string
    age: i32
    
    fn go(self: &Person) {}
}

fn main() {
    val p = Person.{
        name = "Koko",
        age = 20,
    }
    
    val p2: Person = .{ "Jojo", 10 }
    
    val x = p.name.foo.x
    p.go()
}

/***
Module {
    exprs: [
        StructDecl {
            is_public: false,
            name: 'Person',
            fields: [
                StructField {
                    name: 'name',
                    type: string,
                },
                StructField {
                    name: 'age',
                    type: i32,
                },
            ],
            members: [
                FnDecl {
                    name: 'go',
                    is_extern: false,
                    is_public: false,
                    params: [
                        FnParam {
                            is_variadic: false,
                            name: 'self',
                            type: &Person,
                        },
                    ],
                    body: Block {
                        exprs: [],
                    },
                },
            ],
        },
        FnDecl {
            name: 'main',
            is_extern: false,
            is_public: false,
            params: [],
            body: Block {
                exprs: [
                    VarDecl {
                        decl: val,
                        name: 'p',
                        value: StructValue {
                            struct_name: 'Person',
                            elems: [
                                StructValueElem {
                                    field_name: 'name',
                                    value: Lit("Koko"),
                                },
                                StructValueElem {
                                    field_name: 'age',
                                    value: Lit(20),
                                },
                            ],
                        },
                    },
                    VarDecl {
                        decl: val,
                        name: 'p2',
                        type: Person,
                        value: StructValue {
                            elems: [
                                StructValueElem {
                                    value: Lit("Jojo"),
                                },
                                StructValueElem {
                                    value: Lit(10),
                                },
                            ],
                        },
                    },
                    VarDecl {
                        decl: val,
                        name: 'x',
                        value: MemberAccess {
                            calleee: MemberAccess {
                                calleee: MemberAccess {
                                    calleee: Identifier('p'),
                                    member: 'name',
                                },
                                member: 'foo',
                            },
                            member: 'x',
                        },
                    },
                    FnCall {
                        callee: MemberAccess {
                            calleee: Identifier('p'),
                            member: 'go',
                        },
                        args: [],
                    },
                ],
            },
        },
    ],
}
***/