fn main() {
    for a in 0..x {
        foo(a)
    }
    
    for a, i in 0..x {
        foo(a, i)
    }
    
    for a, i in 0..x foo(a, i)
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
                    For {
                        item_var: 'a',
                        iter: Range {
                            lhs: Lit(0),
                            rhs: Identifier('x'),
                            is_eq: false,
                        },
                        body: Block {
                            exprs: [
                                FnCall {
                                    callee: Identifier('foo'),
                                    args: [
                                        Identifier('a'),
                                    ],
                                },
                            ],
                        },
                    },
                    For {
                        item_var: 'a',
                        index_var: 'i',
                        iter: Range {
                            lhs: Lit(0),
                            rhs: Identifier('x'),
                            is_eq: false,
                        },
                        body: Block {
                            exprs: [
                                FnCall {
                                    callee: Identifier('foo'),
                                    args: [
                                        Identifier('a'),
                                        Identifier('i'),
                                    ],
                                },
                            ],
                        },
                    },
                    For {
                        item_var: 'a',
                        index_var: 'i',
                        iter: Range {
                            lhs: Lit(0),
                            rhs: Identifier('x'),
                            is_eq: false,
                        },
                        body: FnCall {
                            callee: Identifier('foo'),
                            args: [
                                Identifier('a'),
                                Identifier('i'),
                            ],
                        },
                    },
                ],
            },
        },
    ],
}
***/