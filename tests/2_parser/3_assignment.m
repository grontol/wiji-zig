fn main() {
    val x = 10
    x = 2
    x += 3
    x *= 4
    x -= 5
    x /= 6
    x %= 7
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
                    VarDecl {
                        decl: val,
                        name: 'x',
                        value: Lit(10),
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(2),
                        op: =,
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(3),
                        op: +=,
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(4),
                        op: *=,
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(5),
                        op: -=,
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(6),
                        op: /=,
                    },
                    Assignment {
                        lhs: Identifier('x'),
                        rhs: Lit(7),
                        op: %=,
                    },
                ],
            },
        },
    ],
}
***/