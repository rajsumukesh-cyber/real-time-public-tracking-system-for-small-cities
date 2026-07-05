# TransitLive — Real-Time Public Transport Tracking System

A full-stack MERN application for tracking public transport in real time. Drivers share
their live GPS location; passengers see buses move on a live map with ETAs, speed, and
route details.

## Stack

| Layer          | Tech                                                    |
| -------------- | -------------------------------------------------------- |
| Frontend       | React 18 (Vite), Tailwind CSS, React Router, Framer Motion, Axios |
| Backend        | Node.js, Express.js                                     |
| Database       | MongoDB (Mongoose)                                      |
| Auth           | JWT + bcrypt, role-based access (driver / passenger / admin) |
| Realtime       | Socket.io                                               |
| Maps           | Google Maps JavaScript API                              |

## Project structure

```
transport-tracker/
├── backend/
│   ├── config/db.js            # Mongo connection
│   ├── models/                 # User, Driver, Passenger, Route, Trip
│   ├── controllers/            # Route handlers per resource
│   ├── routes/                 # Express routers
│   ├── middleware/auth.js      # JWT protect + role authorize
│   ├── sockets/socketHandler.js# Live GPS broadcast logic
│   ├── seed/seedData.js        # Sample users/routes for local testing
│   ├── server.js
│   └── Dockerfile
├── frontend/
│   ├── src/
│   │   ├── pages/              # Landing, Login, Register, driver/*, passenger/*
│   │   ├── components/         # Navbar, Footer, Sidebar, MapView, BusCard...
│   │   ├── context/AuthContext.jsx
│   │   ├── hooks/useGeolocation.js
│   │   └── services/           # api.js (axios), socket.js (socket.io-client)
│   └── Dockerfile
└── docker-compose.yml
```

## 1. Prerequisites

- Node.js 18+
- A MongoDB instance — either [MongoDB Atlas](https://www.mongodb.com/atlas) (free tier works)
  or a local `mongod`
- A [Google Maps JavaScript API key](https://console.cloud.google.com/google/maps-apis)
  with the **Maps JavaScript API** enabled (and billing configured — Google requires a
  billing account even for the free usage tier)

## 2. Backend setup

```bash
cd backend
cp .env.example .env
# edit .env: set MONGO_URI and JWT_SECRET
npm install
npm run seed     # optional: creates sample admin/driver/passenger accounts + routes
npm run dev       # starts on http://localhost:5000
```

Seeded accounts (after `npm run seed`):

| Role      | Email                  | Password    |
| --------- | ----------------------- | ----------- |
| Admin     | admin@transit.com       | admin123    |
| Driver 1  | driver1@transit.com     | driver123   |
| Driver 2  | driver2@transit.com     | driver123   |
| Passenger | passenger1@transit.com  | passenger123|

## 3. Frontend setup

```bash
cd frontend
cp .env.example .env
# edit .env: set VITE_GOOGLE_MAPS_API_KEY and, if backend isn't on localhost:5000, VITE_API_URL / VITE_SOCKET_URL
npm install
npm run dev       # starts on http://localhost:5173
```

Open http://localhost:5173. Register a new driver or passenger account, or log in with
one of the seeded accounts above.

## 4. Running with Docker

A `docker-compose.yml` at the project root spins up MongoDB, the backend, and the
frontend together:

```bash
JWT_SECRET=some_long_random_secret docker compose up --build
```

- Frontend: http://localhost:5173
- Backend API: http://localhost:5000/api
- MongoDB: localhost:27017

Note: the Google Maps API key is baked in at frontend build time via Vite's `%ENV%`
substitution in `index.html`, so set `VITE_GOOGLE_MAPS_API_KEY` in `frontend/.env`
before building the frontend image.

## 5. How live tracking works

1. A driver logs in, taps **Go Online**, and the backend flips their `onlineStatus`.
2. The browser's Geolocation API (`useGeolocation` hook) watches position and emits
   coordinates over Socket.io roughly every 5 seconds.
3. The backend (`sockets/socketHandler.js`) persists the driver's latest location and
   broadcasts it to two Socket.io rooms: the driver's route room (`route:<id>`) and an
   admin room, so any passenger tracking that route sees the bus move instantly.
4. The passenger's `LiveTracking` page keeps a map of `driverId -> position` in state and
   updates the corresponding Google Maps marker in place (no re-creation), so movement is
   smooth rather than a marker "jumping."
5. ETA is estimated client-side from great-circle distance and the bus's current speed —
   good enough for a small-city network; for production accuracy you'd swap this for the
   Google Distance Matrix / Directions API, which accounts for road distance and traffic.

## 6. Key API endpoints

| Method | Endpoint                              | Access           | Purpose                        |
| ------ | -------------------------------------- | ---------------- | ------------------------------- |
| POST   | /api/auth/register                     | Public           | Create driver/passenger account |
| POST   | /api/auth/login                        | Public           | Log in, returns JWT             |
| GET    | /api/auth/me                           | Authenticated    | Current user                    |
| GET    | /api/drivers/live                      | Authenticated    | All online drivers (map)        |
| PATCH  | /api/drivers/status                    | Driver           | Go online / offline             |
| POST   | /api/drivers/trips/start               | Driver           | Start a trip                    |
| POST   | /api/drivers/trips/:tripId/end         | Driver           | End a trip                      |
| GET    | /api/passengers/search?query=          | Passenger        | Search buses/routes             |
| PATCH  | /api/passengers/favorites/:routeId     | Passenger        | Toggle favorite route           |
| GET    | /api/routes                            | Authenticated    | List active routes              |

Socket.io events are documented at the top of `backend/sockets/socketHandler.js`.

## 7. What's scaffolded vs. what to extend

This is a complete, runnable full-stack scaffold covering registration/login, both
dashboards, live GPS tracking end-to-end, route/trip management, search, favorites, and
saved stops. A few things flagged as "optional" in the brief (a full admin analytics UI
with charts, push notifications, and a dedicated emergency-alerts inbox) are wired up at
the data/socket level (the `sos` event, `Trip` history, admin-only routes) but don't yet
have a dedicated admin dashboard UI — that's the natural next module to build on top of
this foundation.
