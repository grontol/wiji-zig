fn main() {
    1 + 2
    1 + 2 * 3
    (1 + 2) * 3
    4 % 3 * 3 / 10 + (2 - 4)
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
                    Binary {
                        op: +,
                        lhs: Lit(1),
                        rhs: Lit(2),
                    },
                    Binary {
                        op: +,
                        lhs: Lit(1),
                        rhs: Binary {
                            op: *,
                            lhs: Lit(2),
                            rhs: Lit(3),
                        },
                    },
                    Binary {
                        op: *,
                        lhs: Binary {
                            op: +,
                            lhs: Lit(1),
                            rhs: Lit(2),
                        },
                        rhs: Lit(3),
                    },
                    Binary {
                        op: +,
                        lhs: Binary {
                            op: /,
                            lhs: Binary {
                                op: *,
                                lhs: Binary {
                                    op: %,
                                    lhs: Lit(4),
                                    rhs: Lit(3),
                                },
                                rhs: Lit(3),
                            },
                            rhs: Lit(10),
                        },
                        rhs: Binary {
                            op: -,
                            lhs: Lit(2),
                            rhs: Lit(4),
                        },
                    },
                ],
            },
        },
    ],
}
***/