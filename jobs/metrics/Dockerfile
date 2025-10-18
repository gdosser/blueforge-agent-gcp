# Use a minimal Node.js 20 base image
FROM node:20-slim

# Set working directory inside the container
WORKDIR /app

# Copy only dependency declarations first (for better layer caching)
COPY package*.json ./

# Install production dependencies
RUN npm install --omit=dev

# Copy the rest of the application code
COPY . .

# Default command to run the job
CMD ["node", "job.js"]