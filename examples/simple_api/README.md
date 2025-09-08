# Example: Simple Api

```sh
docker compose up -d # Start postgres database
make start           # Run the server
```

This example shows usage of `ewe` package. It's an api with simple authentication and crud operations on todo tasks.

## Api Reference

### POST /auth/register

#### Request Body (application/json)
- username: string
- password: string

#### Responses (application/json)
- 201 Created:
  - message: "User created"
- 409 Conflict:
  - error: "User already exists"

### POST /auth/login

#### Request Body (application/json)
- username: string
- password: string

#### Responses (application/json)
- 200 OK:
  - message: "Login successful"
- 401 Conflict:
  - error: "Invalid username or password"

### GET /session

#### Authorization
- Session cookie

#### Responses (application/json)
- 200 OK:
  - id: int
  - username: string

### POST /auth/logout

#### Authorization
- Session cookie

#### Responses (application/json)
- 200 OK:
  - message: "Logout successful"

### POST /tasks

#### Authorization
- Session cookie

#### Request Body (application/json)
- title: string
- description: string
- completed?: bool

#### Responses (application/json)
- 201 Created:
  - id: number
  - title: string
  - description: string
  - completed: bool

### GET /tasks

#### Authorization
- Session cookie

#### Query Parameters
- completed: bool

#### Responses (application/json)
- 200 OK:
  - array of:
    - id: number
    - title: string
    - description: string
    - completed: bool

### PUT /tasks/:id

#### Authorization
- Session cookie

#### Request Body (application/json)
- title?: string
- description?: string
- completed?: bool

#### Responses (application/json)
- 200 OK:
  - id: number
  - title: string
  - description: string
  - completed: bool
- 404 Not Found:
  - error: "Task not found"

### DELETE /tasks/:id

#### Authorization
- Session cookie

#### Responses (application/json)
- 200 OK:
  - message: "Task deleted"
- 404 Not Found:
  - error: "Task not found"