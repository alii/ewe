--- migration:up
create table users (
  id serial primary key,
  username varchar(255) not null unique,
  password_hash text not null
);

create table tasks (
  id serial primary key,
  title varchar(255) not null,
  description text not null,
  completed boolean default false,
  user_id int not null references users(id)
);
--- migration:down
drop table tasks;
drop table users;
--- migration:end