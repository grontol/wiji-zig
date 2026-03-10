fn main() {
    if a < 20 foo() else goo()
    if a < 20 foo() else if a < 50 hoo() else goo()
    
    val x = if foo() 10 else 20
    
    if (a + 4) > 10 {
        foo()
        hoo()
    }
    else {
        goo()
    }
}

/***
Module {
    exprs: [
        FnDecl {
            name: 'main',
            is_extern: false,
            is_public: false,
            params: [],
            body: Block {
                exprs: [
                    If {
                        condition: Binary {
                            op: <,
                            lhs: Identifier('a'),
                            rhs: Lit(20),
                        },
                        body: FnCall {
                            callee: Identifier('foo'),
                            args: [],
                        },
                        else: FnCall {
                            callee: Identifier('goo'),
                            args: [],
                        },
                    },
                    If {
                        condition: Binary {
                            op: <,
                            lhs: Identifier('a'),
                            rhs: Lit(20),
                        },
                        body: FnCall {
                            callee: Identifier('foo'),
                            args: [],
                        },
                        else: If {
                            condition: Binary {
                                op: <,
                                lhs: Identifier('a'),
                                rhs: Lit(50),
                            },
                            body: FnCall {
                                callee: Identifier('hoo'),
                                args: [],
                            },
                            else: FnCall {
                                callee: Identifier('goo'),
                                args: [],
                            },
                        },
                    },
                    VarDecl {
                        decl: val,
                        name: 'x',
                        value: If {
                            condition: FnCall {
                                callee: Identifier('foo'),
                                args: [],
                            },
                            body: Lit(10),
                            else: Lit(20),
                        },
                    },
                    If {
                        condition: Binary {
                            op: >,
                            lhs: Binary {
                                op: +,
                                lhs: Identifier('a'),
                                rhs: Lit(4),
                            },
                            rhs: Lit(10),
                        },
                        body: Block {
                            exprs: [
                                FnCall {
                                    callee: Identifier('foo'),
                                    args: [],
                                },
                                FnCall {
                                    callee: Identifier('hoo'),
                                    args: [],
                                },
                            ],
                        },
                        else: Block {
                            exprs: [
                                FnCall {
                                    callee: Identifier('goo'),
                                    args: [],
                                },
                            ],
                        },
                    },
                ],
            },
        },
    ],
}
***/