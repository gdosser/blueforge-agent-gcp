class CustomError extends Error {
    constructor(type, message, cause) {
        super(message, { cause });
        this.type = type;
    }
}

export const Type = {
    INVALID: 400,
    FORBIDDEN: 403,
    NOT_FOUND: 404,
    UNEXPECTED: 500,
}

export default {
    INVALID: (message, cause) => new CustomError(Type.INVALID, message || 'An unknown error occurs.', cause),
    FORBIDDEN: (message, cause) => new CustomError(Type.FORBIDDEN, message || 'You are not authorized to perform this operation.', cause),
    NOT_FOUND: (message, cause) => new CustomError(Type.NOT_FOUND, message || 'We did not find what you are looking for.', cause),
    UNEXPECTED: (message, cause) => new CustomError(Type.UNEXPECTED, message || 'An unexpected error occurs.', cause),
}